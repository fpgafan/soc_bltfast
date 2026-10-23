// ============================================================================
// video.v - 640x480@60 video controller, 8 bpp framebuffer with palette
//
//  sys domain: registers, line DMA from SDRAM (master 0), palette
//  pix domain: 800x525 timing at 25.2 MHz, line buffer and palette
//              reads, RGB888 output + syncs
//
//  Hardware scrolling: each visible line y is read from row
//     r = (SCROLL_Y + y) mod WRAP_H              (no wrap if WRAP_H = 0)
//  of the canvas starting at FB_BASE with FB_STRIDE bytes per row, starting
//  at column SCROLL_X; with WRAP_W = n (n >= 2) the row is treated as a
//  ring of 2^n * 256 bytes (infinite horizontal scrolling).
//  Registers are latched at the start of each frame (tear-free double
//  buffering) or on every line if CTRL.LIVE = 1 (raster effects).
//
//  Registers (base 0x8000_2000):
//   +0x00 CTRL      [0] enable, [1] LIVE, [2] HDMI (data islands, audio)
//   +0x04 FB_BASE   byte address (0x4xxx_xxxx or offset)
//   +0x08 STRIDE    bytes per row (multiple of 4)
//   +0x0C SCROLL_X  pixels
//   +0x10 SCROLL_Y  rows
//   +0x14 WRAP_W    [3:0] n: horizontal ring of 2^n * 256 bytes (0 = off)
//   +0x18 WRAP_H    canvas rows for vertical wrap (0 = off)
//   +0x1C BORDER    color index when the display is disabled
//   +0x20 RASTER    line of the RASTER interrupt
//   +0x24 STATUS    R: [9:0] line being prepared, [16] vblank, [31:20] frames
//   +0x28 PENDING   R: [0] register change pending
//   Palette: 0x8000_3000 + 4*i = 0x00RRGGBB (write only)
// ============================================================================
`default_nettype none
module video (
    input  wire        clk,             // sys
    input  wire        rst,
    input  wire        clk_pix,
    input  wire        rst_pix,
    // registers
    input  wire        sel,
    input  wire        pal_sel,
    input  wire        we,
    input  wire [5:0]  a,
    input  wire [7:0]  pal_a,
    input  wire [31:0] wd,
    output reg  [31:0] rd,
    output reg         irq_vblank,      // pulses (sys domain)
    output reg         irq_raster,
    // SDRAM master (read)
    output reg         m_req,
    output reg  [22:2] m_addr,
    output reg  [3:0]  m_len,
    input  wire        m_ack,
    input  wire [31:0] m_rdata,
    input  wire        m_rvalid,
    // output (pix domain)
    output reg  [23:0] rgb,
    output reg         hsync,
    output reg         vsync,
    output reg         de,
    output reg  [9:0]  pix_hcount,      // aligned with rgb/de
    output reg  [9:0]  pix_vcount,
    output reg         hdmi_mode        // sys domain (quasi-static)
);
    // =====================================================================
    // Registers (sys)
    // =====================================================================
    reg        r_en, r_live, r_hdmi;
    reg [22:0] r_base;
    reg [13:0] r_stride;
    reg [12:0] r_sx;
    reg [10:0] r_sy;
    reg [3:0]  r_ww;
    reg [10:0] r_wh;
    reg [7:0]  r_border;
    reg [9:0]  r_raster;
    reg        r_dirty;
    // active copy (used while preparing lines)
    reg        c_en;
    reg [22:0] c_base;
    reg [13:0] c_stride;
    reg [12:0] c_sx;
    reg [10:0] c_sy;
    reg [3:0]  c_ww;
    reg [10:0] c_wh;
    reg [7:0]  c_border;

    reg [9:0]  cur_line;
    reg        in_vblank;
    reg [11:0] frames;

    // =====================================================================
    // Timing (pix)
    // =====================================================================
    localparam H_VIS = 640, H_FP = 16, H_SYNC = 96, H_BP = 48, H_TOT = 800;
    localparam V_VIS = 480, V_FP = 10, V_SYNC = 2, V_BP = 33, V_TOT = 525;
    reg [9:0] hc, vc;
    reg [9:0] hc1, hc2, hc3, vc1, vc2, vc3;
    always @(posedge clk_pix) begin
        hc1 <= hc;  hc2 <= hc1; hc3 <= hc2; pix_hcount <= hc3;
        vc1 <= vc;  vc2 <= vc1; vc3 <= vc2; pix_vcount <= vc3;
    end

    // line request: at the start of each line vc, line vc+1 is prepared
    reg        lreq_tgl;
    reg [9:0]  lreq_line;               // stable while the toggle travels
    reg        vbl_tgl;

    always @(posedge clk_pix) begin
        if (rst_pix) begin
            hc <= 10'd0; vc <= 10'd0;
            lreq_tgl <= 1'b0; vbl_tgl <= 1'b0;
            lreq_line <= 10'd0;
        end else begin
            if (hc == H_TOT - 1) begin
                hc <= 10'd0;
                vc <= (vc == V_TOT - 1) ? 10'd0 : vc + 10'd1;
            end else
                hc <= hc + 10'd1;
            if (hc == 10'd0) begin
                // line to prepare: vc+1 (or 0 during the last line)
                if (vc == V_TOT - 1) begin
                    lreq_line <= 10'd0;
                    lreq_tgl  <= ~lreq_tgl;
                end else if (vc < V_VIS - 1) begin
                    lreq_line <= vc + 10'd1;
                    lreq_tgl  <= ~lreq_tgl;
                end
                if (vc == V_VIS) vbl_tgl <= ~vbl_tgl;
            end
        end
    end

    // =====================================================================
    // pix -> sys crossing
    // =====================================================================
    reg [2:0] lreq_s, vbl_s;
    always @(posedge clk) begin
        lreq_s <= {lreq_s[1:0], lreq_tgl};
        vbl_s  <= {vbl_s[1:0], vbl_tgl};
    end
    wire lreq_ev = lreq_s[2] ^ lreq_s[1];
    wire vbl_ev  = vbl_s[2] ^ vbl_s[1];

    // =====================================================================
    // Line buffer: 2 x 256 words (sys writes, pix reads)
    // =====================================================================
    reg [31:0] lbuf [0:511];
    reg        lb_we;
    reg [8:0]  lb_wa;
    reg [31:0] lb_wd;
    always @(posedge clk) if (lb_we) lbuf[lb_wa] <= lb_wd;

    // =====================================================================
    // Line DMA (sys)
    // =====================================================================
    localparam D_IDLE = 3'd0, D_REQ = 3'd1, D_ROW = 3'd2, D_DATA = 3'd3, D_ROW2 = 3'd4;
    reg [2:0]  dst;
    reg [11:0] f_rsum;
    reg        lpend;                   // line request pending
    reg [9:0]  lpend_line;
    reg        f_half;                  // buffer half (line & 1)
    reg [9:0]  f_line;
    reg [10:0] f_row;                   // canvas row for the line
    reg [22:0] f_rowaddr;               // base + row*stride
    reg [12:0] f_col;                   // column (bytes) of the next word
    reg [7:0]  f_left;                  // remaining words
    reg [7:0]  f_widx;                  // write index into the buffer
    reg [4:0]  f_burst;                 // words in the current burst
    reg [1:0]  f_fine [0:1];            // fine offset per half
    reg        f_blank [0:1];           // blank line (display disabled)
    reg [7:0]  f_bcol [0:1];

    // burst length: up to 16 words, without crossing 1 KB or the wrap point.
    // Computed in two cycles: D_DATA alternates between preparing (f_prep) and requesting.
    reg  [12:0] wrap_m;                 // ring mask (all ones if no wrap)
    reg  [12:0] wrap_b;                 // ring size in bytes
    reg         f_prep;
    reg  [22:0] wa_q;                   // byte address of the burst
    reg  [12:0] colm_q;
    reg  [8:0]  to_row_q;               // words up to the 1 KB boundary (1..256)
    reg  [10:0] to_wrap_q;              // words up to the end of the ring
    wire [12:0] col_m   = f_col & wrap_m;
    wire [22:0] wa_byte = f_rowaddr + {10'd0, col_m};
    reg  [4:0]  blen;
    always @(*) begin
        blen = (f_left > 8'd16) ? 5'd16 : f_left[4:0];
        if (to_row_q < {4'd0, blen}) blen = to_row_q[4:0];
        if (c_ww != 4'd0 && to_wrap_q < {6'd0, blen}) blen = to_wrap_q[4:0];
    end

    always @(posedge clk) begin
        lb_we      <= 1'b0;
        irq_vblank <= 1'b0;
        irq_raster <= 1'b0;
        if (rst) begin
            dst <= D_IDLE;
            lpend <= 1'b0;
            m_req <= 1'b0;
            r_en <= 1'b1; r_live <= 1'b0; r_hdmi <= 1'b1; r_base <= 23'h60_0000; r_stride <= 14'd640;
            r_sx <= 13'd0; r_sy <= 11'd0; r_ww <= 4'd0; r_wh <= 11'd0; r_border <= 8'd0;
            r_raster <= 10'd0; r_dirty <= 1'b1;
            c_en <= 1'b0;
            cur_line <= 10'd0; in_vblank <= 1'b0; frames <= 12'd0;
        end else begin
            // -------------------------------------------- register writes
            if (sel & we) begin
                case (a[5:2])
                4'h0: begin r_en <= wd[0]; r_live <= wd[1]; r_hdmi <= wd[2]; end
                4'h1: r_base   <= wd[22:0];
                4'h2: r_stride <= {wd[13:2], 2'b00};
                4'h3: r_sx     <= wd[12:0];
                4'h4: r_sy     <= wd[10:0];
                4'h5: r_ww     <= wd[3:0];
                4'h6: r_wh     <= wd[10:0];
                4'h7: r_border <= wd[7:0];
                4'h8: r_raster <= wd[9:0];
                default: ;
                endcase
                if (a[5:2] <= 4'h7) r_dirty <= 1'b1;
            end

            if (vbl_ev) begin
                in_vblank  <= 1'b1;
                irq_vblank <= 1'b1;
                frames     <= frames + 12'd1;
            end

            // -------------------------------------------- new line
            if (lreq_ev) begin
                cur_line <= lreq_line;
                if (lreq_line == r_raster) irq_raster <= 1'b1;
                if (lreq_line == 10'd0) in_vblank <= 1'b0;
                lpend      <= 1'b1;
                lpend_line <= lreq_line;
            end

            case (dst)
            D_IDLE: if (lpend) begin
                lpend <= 1'b0;
                // latch registers: at frame start, or on every line in LIVE mode
                if (lpend_line == 10'd0 || r_live) begin
                    c_en <= r_en; c_base <= r_base; c_stride <= r_stride;
                    c_sx <= r_sx; c_sy <= r_sy; c_ww <= r_ww; c_wh <= r_wh;
                    c_border <= r_border;
                    r_dirty <= 1'b0;
                end
                f_half <= lpend_line[0];
                f_line <= lpend_line;
                f_widx <= 8'd0;
                dst    <= D_REQ;
            end
            D_REQ: begin
                // canvas row for this line (c_* registers already latched)
                // row = (SCROLL_Y + line) mod WRAP_H, in two steps (D_REQ and D_ROW)
                f_rsum <= {1'b0, c_sy} + {2'd0, f_line};
                f_col <= {c_sx[12:2], 2'b00};
                f_fine[f_half]  <= c_sx[1:0];
                f_blank[f_half] <= ~c_en;
                f_bcol[f_half]  <= c_border;
                f_left  <= 8'd160 + {7'd0, (c_sx[1:0] != 2'd0)};
                f_burst <= 5'd0;
                f_prep  <= 1'b1;
                wrap_m  <= (c_ww == 4'd0) ? 13'h1FFF : ((13'd256 << c_ww) - 13'd1);
                wrap_b  <= (c_ww == 4'd0) ? 13'h0 : (13'd256 << c_ww);
                dst     <= c_en ? D_ROW : D_IDLE;
            end
            D_ROW: begin
                if (c_wh != 11'd0 && f_rsum >= {1'b0, c_wh})
                    f_row <= (f_rsum - {1'b0, c_wh} >= {1'b0, c_wh}) ? f_rsum[10:0] - {c_wh[9:0], 1'b0}
                                                                     : f_rsum[10:0] - c_wh;
                else
                    f_row <= f_rsum[10:0];
                dst <= D_ROW2;
            end
            D_ROW2: dst <= D_DATA;          // wait for f_rowaddr (multiplication)
            D_DATA: begin
                if (f_burst == 5'd0 && !m_req) begin
                    if (f_left == 8'd0)
                        dst <= D_IDLE;
                    else if (f_prep) begin
                        // cycle 1: address and distances to the boundaries
                        wa_q      <= wa_byte;
                        colm_q    <= col_m;
                        to_row_q  <= 9'd256 - {1'b0, wa_byte[9:2]};
                        to_wrap_q <= (wrap_b - col_m) >> 2;
                        f_prep    <= 1'b0;
                    end else begin
                        // cycle 2: request
                        m_req   <= 1'b1;
                        m_addr  <= wa_q[22:2];
                        m_len   <= blen - 5'd1;
                        f_burst <= blen;
                        f_col   <= colm_q + {6'd0, blen, 2'b00};
                        f_left  <= f_left - {3'd0, blen};
                        f_prep  <= 1'b1;
                    end
                end
                if (m_ack) m_req <= 1'b0;
                if (m_rvalid) begin
                    lb_we   <= 1'b1;
                    lb_wa   <= {f_half, f_widx};
                    lb_wd   <= m_rdata;
                    f_widx  <= f_widx + 8'd1;
                    f_burst <= f_burst - 5'd1;
                end
            end
            default: ;
            endcase
        end
    end

    // row address (incremental multiplication avoided: DSP)
    always @(posedge clk) f_rowaddr <= c_base + f_row * c_stride;

    always @(posedge clk) hdmi_mode <= r_hdmi;

    // register reads
    always @(posedge clk) begin
        case (a[5:2])
        4'h0: rd <= {29'd0, r_hdmi, r_live, r_en};
        4'h1: rd <= {9'd0, r_base};
        4'h2: rd <= {18'd0, r_stride};
        4'h3: rd <= {19'd0, r_sx};
        4'h4: rd <= {21'd0, r_sy};
        4'h5: rd <= {28'd0, r_ww};
        4'h6: rd <= {21'd0, r_wh};
        4'h7: rd <= {24'd0, r_border};
        4'h8: rd <= {22'd0, r_raster};
        4'h9: rd <= {frames, 3'd0, in_vblank, 6'd0, cur_line};
        4'hA: rd <= {31'd0, r_dirty};
        default: rd <= 32'd0;
        endcase
    end

    // =====================================================================
    // Palette: 256 x 24 (sys writes, pix reads)
    // =====================================================================
    reg [23:0] pal [0:255];
    integer pi;
    initial for (pi = 0; pi < 256; pi = pi + 1) pal[pi] = {pi[7:0], pi[7:0], pi[7:0]};
    always @(posedge clk) if (pal_sel & we) pal[pal_a] <= wd[23:0];

    // =====================================================================
    // Pixel output (pix)
    //   stage 0: hc/vc -> line buffer address
    //   stage 1: word read -> byte
    //   stage 2: palette -> RGB
    // =====================================================================
    // the f_fine/f_blank variables of the half being displayed are stable
    // for the whole line (they were written one line earlier)
    wire        vis  = (hc < H_VIS) && (vc < V_VIS);
    wire        half = vc[0];
    wire [9:0]  bidx = hc + {8'd0, f_fine[half]};
    reg  [31:0] lq;
    reg  [1:0]  bsel1;
    reg         vis1, blank1, hs1, vs1;
    reg  [7:0]  bcol1;
    always @(posedge clk_pix) begin
        lq     <= lbuf[{half, bidx[9:2]}];
        bsel1  <= bidx[1:0];
        vis1   <= vis;
        blank1 <= f_blank[half];
        bcol1  <= f_bcol[half];
        hs1    <= ~((hc >= H_VIS + H_FP) && (hc < H_VIS + H_FP + H_SYNC));
        vs1    <= ~((vc >= V_VIS + V_FP) && (vc < V_VIS + V_FP + V_SYNC));
    end
    reg [7:0] idx2;
    reg       vis2, hs2, vs2;
    always @(posedge clk_pix) begin
        case (bsel1)
        2'd0: idx2 <= blank1 ? bcol1 : lq[7:0];
        2'd1: idx2 <= blank1 ? bcol1 : lq[15:8];
        2'd2: idx2 <= blank1 ? bcol1 : lq[23:16];
        default: idx2 <= blank1 ? bcol1 : lq[31:24];
        endcase
        vis2 <= vis1; hs2 <= hs1; vs2 <= vs1;
    end
    reg [23:0] pq;
    reg        vis3, hs3, vs3;
    always @(posedge clk_pix) begin
        pq   <= pal[idx2];
        vis3 <= vis2; hs3 <= hs2; vs3 <= vs2;
    end
    always @(posedge clk_pix) begin
        rgb   <= vis3 ? pq : 24'd0;
        de    <= vis3;
        hsync <= hs3;
        vsync <= vs3;
    end
endmodule
`default_nettype wire
