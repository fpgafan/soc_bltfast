// ============================================================================
// hdmi_tx.v - HDMI transmitter (640x480@60, 25.2 MHz) with 48 kHz PCM audio
//
//   - TMDS 8b/10b video coding, control tokens, TERC4
//   - Preambles and guard bands for video and data islands
//   - One data island per line (2 packets) in the horizontal blanking:
//       packet 0: audio samples (or null if none)
//       packet 1: rotates between ACR (N = 6144, CTS = 25200), AVI InfoFrame,
//                 ACR and Audio InfoFrame
//   - BCH(64,56)/(32,24) ECC computed on the fly while transmitting
//   - 10:1 serialization with OSER10 (FCLK = 126 MHz) and ELVDS outputs
//   hdmi_en = 0: plain DVI output (no islands or island preambles)
// ============================================================================
`default_nettype none
module hdmi_tx (
    input  wire        clk_pix,
    input  wire        clk_ser,
    input  wire        rst,
    input  wire        hdmi_en,
    // video (aligned with hc/vc)
    input  wire [23:0] rgb,
    input  wire        de,
    input  wire        hsync,           // line polarity (active low in 640x480)
    input  wire        vsync,
    input  wire [9:0]  hc,
    input  wire [9:0]  vc,
    // audio (pix domain)
    input  wire        aud_we,
    input  wire [15:0] aud_l,
    input  wire [15:0] aud_r,
    // output
    output wire        tmds_clk_p, tmds_clk_n,
    output wire [2:0]  tmds_d_p,   tmds_d_n,
    // debug / test
    output wire [29:0] tmds_word
);
    localparam W = 640, H = 480, FW = 800, FH = 525;
    localparam NPK = 2;
    localparam DI_PRE = W + 4, DI_GL = W + 12, DI_ST = W + 14, DI_END = W + 14 + NPK * 32;

    // ---------------------------------------------------------------- audio FIFO
    reg [31:0] af [0:7];
    reg [2:0]  af_wp, af_rp;
    reg [3:0]  af_n;
    wire       af_pop;
    wire [2:0] af_take;              // samples to take in this packet (0..2)

    // ---------------------------------------------------------------- position
    reg [4:0]  pcnt;                 // pixel within the packet
    reg        pidx;                 // packet 0/1
    wire in_di_pre  = hdmi_en && hc >= DI_PRE && hc < DI_GL;
    wire in_di_gd   = hdmi_en && ((hc >= DI_GL && hc < DI_ST) || (hc >= DI_END && hc < DI_END + 2));
    wire in_di      = hdmi_en && hc >= DI_ST && hc < DI_END;
    wire next_vis   = (vc < H - 1) || (vc == FH - 1);   // the next line has video
    wire in_vid_pre = next_vis && hc >= FW - 10 && hc < FW - 2;
    wire in_vid_gd  = hdmi_en && next_vis && hc >= FW - 2;

    // ---------------------------------------------------------------- packets
    reg [55:0] sp00, sp01, sp02, sp03, sp10, sp11, sp12, sp13;
    reg [23:0] hd0, hd1;

    reg [7:0]  frame_ctr;            // IEC 60958 frame counter (0..191)
    reg [1:0]  rot;                  // packet 1 rotation

    // channel status (consumer, PCM, no copyright, 48 kHz)
    function cs_bit(input [7:0] idx, input right);
        begin
            case (idx)
            8'd2:  cs_bit = 1'b1;            // copyright not asserted
            8'd20: cs_bit = ~right;          // channel 1 (left)
            8'd21: cs_bit = right;           // channel 2 (right)
            8'd25: cs_bit = 1'b1;            // 48 kHz = 0010
            default: cs_bit = 1'b0;
            endcase
        end
    endfunction

    function [55:0] asp_sub(input [15:0] l, input [15:0] r, input [7:0] fidx);
        reg [23:0] l24, r24;
        reg cl, cr, pl, pr;
        begin
            l24 = {l, 8'd0};
            r24 = {r, 8'd0};
            cl  = cs_bit(fidx, 1'b0);
            cr  = cs_bit(fidx, 1'b1);
            pl  = ^{cl, 1'b0, 1'b0, l24};
            pr  = ^{cr, 1'b0, 1'b0, r24};
            asp_sub = {pr, cr, 1'b0, 1'b0, pl, cl, 1'b0, 1'b0, r24, l24};
        end
    endfunction

    // InfoFrames (constant checksums)
    // AVI v2, length 13: PB1 = 0x00 (RGB), PB2 = 0x18 (4:3, same), PB3 = 0x08 (full
    // range), PB4 = VIC 1
    localparam [7:0] AVI_SUM = 8'h82 + 8'h02 + 8'h0D + 8'h00 + 8'h18 + 8'h08 + 8'h01;
    localparam [7:0] AVI_CK  = 8'h00 - AVI_SUM;
    // Audio v1, length 10: PB1 = 0x01 (2 channels), rest 0
    localparam [7:0] AIF_SUM = 8'h84 + 8'h01 + 8'h0A + 8'h01;
    localparam [7:0] AIF_CK  = 8'h00 - AIF_SUM;

    wire [7:0] f1 = (frame_ctr == 8'd191) ? 8'd0 : frame_ctr + 8'd1;
    assign af_take = (af_n >= 4'd2) ? 3'd2 : (af_n == 4'd1) ? 3'd1 : 3'd0;
    wire load_pk = hdmi_en && (hc == DI_ST - 1);
    assign af_pop = load_pk;

    always @(posedge clk_pix) begin
        if (rst) begin
            af_wp <= 3'd0; af_rp <= 3'd0; af_n <= 4'd0;
            frame_ctr <= 8'd0; rot <= 2'd0;
            hd0 <= 24'd0; hd1 <= 24'd0;
        end else begin
            // FIFO write (discarded if full)
            if (aud_we && af_n != 4'd8) begin
                af[af_wp] <= {aud_r, aud_l};
                af_wp <= af_wp + 3'd1;
            end
            af_n <= af_n + ((aud_we && af_n != 4'd8) ? 4'd1 : 4'd0) - (af_pop ? {1'b0, af_take} : 4'd0);
            if (load_pk) begin
                // ---------------- packet 0: audio samples
                if (af_take == 3'd0) begin
                    hd0 <= 24'd0;
                    sp00 <= 56'd0; sp01 <= 56'd0;
                end else begin
                    // HB2 = {B3..B0, flat3..0}, HB1 = {000, layout=0, present3..0}, HB0 = 0x02
                    hd0 <= {2'b00, (af_take == 3'd2) && (f1 == 8'd0), frame_ctr == 8'd0, 4'b0000,
                            4'b0000, 2'b00, af_take == 3'd2, 1'b1,
                            8'h02};
                    sp00 <= asp_sub(af[af_rp][15:0], af[af_rp][31:16], frame_ctr);
                    sp01 <= (af_take == 3'd2) ? asp_sub(af[af_rp + 3'd1][15:0], af[af_rp + 3'd1][31:16], f1) : 56'd0;
                    af_rp <= af_rp + af_take;
                    frame_ctr <= (af_take == 3'd2) ? ((f1 == 8'd191) ? 8'd0 : f1 + 8'd1) : f1;
                end
                sp02 <= 56'd0; sp03 <= 56'd0;
                // ---------------- packet 1: rotation
                rot <= rot + 2'd1;
                case (rot)
                2'd1: begin                                   // AVI InfoFrame
                    hd1 <= {8'h0D, 8'h02, 8'h82};
                    sp10 <= {8'h00, 8'h00, 8'h01, 8'h08, 8'h18, 8'h00, AVI_CK};
                    sp11 <= 56'd0; sp12 <= 56'd0; sp13 <= 56'd0;
                end
                2'd3: begin                                   // Audio InfoFrame
                    hd1 <= {8'h0A, 8'h01, 8'h84};
                    sp10 <= {8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h01, AIF_CK};
                    sp11 <= 56'd0; sp12 <= 56'd0; sp13 <= 56'd0;
                end
                default: begin                                // ACR: N = 6144, CTS = 25200
                    hd1 <= {8'h00, 8'h00, 8'h01};
                    sp10 <= {8'h00, 8'h18, 8'h00, 8'h70, 8'h62, 8'h00, 8'h00};
                    sp11 <= {8'h00, 8'h18, 8'h00, 8'h70, 8'h62, 8'h00, 8'h00};
                    sp12 <= {8'h00, 8'h18, 8'h00, 8'h70, 8'h62, 8'h00, 8'h00};
                    sp13 <= {8'h00, 8'h18, 8'h00, 8'h70, 8'h62, 8'h00, 8'h00};
                end
                endcase
            end
        end
    end

    // ---------------------------------------------------------------- assembly + ECC
    function [7:0] next_ecc(input [7:0] ecc, input b);
        next_ecc = (ecc >> 1) ^ ((ecc[0] ^ b) ? 8'b1000_0011 : 8'd0);
    endfunction

    reg [7:0] par [0:4];
    wire [23:0] ch  = pidx ? hd1 : hd0;
    wire [55:0] cs0 = pidx ? sp10 : sp00;
    wire [55:0] cs1 = pidx ? sp11 : sp01;
    wire [55:0] cs2 = pidx ? sp12 : sp02;
    wire [55:0] cs3 = pidx ? sp13 : sp03;
    wire [63:0] b0 = {par[0], cs0}, b1 = {par[1], cs1}, b2 = {par[2], cs2}, b3 = {par[3], cs3};
    wire [31:0] bh = {par[4], ch};
    wire [5:0]  i2 = {pcnt, 1'b0};
    wire [5:0]  i3 = {pcnt, 1'b1};
    wire        hbit = bh[pcnt];
    wire [3:0]  d1 = {b3[i2], b2[i2], b1[i2], b0[i2]};
    wire [3:0]  d2 = {b3[i3], b2[i3], b1[i3], b0[i3]};

    integer q;
    always @(posedge clk_pix) begin
        if (rst || !in_di) begin
            pcnt <= 5'd0; pidx <= 1'b0;
            for (q = 0; q < 5; q = q + 1) par[q] <= 8'd0;
        end else begin
            pcnt <= pcnt + 5'd1;
            if (pcnt == 5'd31) pidx <= ~pidx;
            if (pcnt < 5'd28) begin
                par[0] <= next_ecc(next_ecc(par[0], cs0[i2]), cs0[i3]);
                par[1] <= next_ecc(next_ecc(par[1], cs1[i2]), cs1[i3]);
                par[2] <= next_ecc(next_ecc(par[2], cs2[i2]), cs2[i3]);
                par[3] <= next_ecc(next_ecc(par[3], cs3[i2]), cs3[i3]);
                if (pcnt < 5'd24) par[4] <= next_ecc(par[4], ch[pcnt]);
            end else if (pcnt == 5'd31)
                for (q = 0; q < 5; q = q + 1) par[q] <= 8'd0;
        end
    end

    // ---------------------------------------------------------------- mode select
    localparam M_CTL = 3'd0, M_VID = 3'd1, M_VGD = 3'd2, M_DI = 3'd3, M_DGD = 3'd4;
    reg [2:0]  mode;
    reg [23:0] vdat;
    reg [5:0]  ctl;                  // {ctl3, ctl2, ctl1, ctl0, vsync, hsync}
    reg [11:0] didat;
    always @(posedge clk_pix) begin
        mode  <= de ? M_VID : in_vid_gd ? M_VGD : in_di ? M_DI : in_di_gd ? M_DGD : M_CTL;
        vdat  <= rgb;
        ctl   <= {1'b0, in_di_pre, 1'b0, in_vid_pre | in_di_pre, vsync, hsync};
        didat <= {d2, d1, 1'b1, hbit, vsync, hsync};
    end

    // ---------------------------------------------------------------- TMDS per channel
    wire [9:0] t0, t1, t2;
    tmds_chan #(.CN(0)) u_c0 (.clk(clk_pix), .rst(rst), .mode(mode), .vd(vdat[7:0]),
                              .cd(ctl[1:0]), .dd(didat[3:0]), .q(t0));
    tmds_chan #(.CN(1)) u_c1 (.clk(clk_pix), .rst(rst), .mode(mode), .vd(vdat[15:8]),
                              .cd(ctl[3:2]), .dd(didat[7:4]), .q(t1));
    tmds_chan #(.CN(2)) u_c2 (.clk(clk_pix), .rst(rst), .mode(mode), .vd(vdat[23:16]),
                              .cd(ctl[5:4]), .dd(didat[11:8]), .q(t2));
    assign tmds_word = {t2, t1, t0};

    // ---------------------------------------------------------------- serialization
    wire [9:0] tw [0:3];
    assign tw[0] = t0; assign tw[1] = t1; assign tw[2] = t2; assign tw[3] = 10'b0000011111;
    wire [3:0] ser;
    genvar g;
    generate for (g = 0; g < 4; g = g + 1) begin : g_ser
        OSER10 #(.GSREN("false"), .LSREN("true")) u_ser (
            .Q(ser[g]), .D0(tw[g][0]), .D1(tw[g][1]), .D2(tw[g][2]), .D3(tw[g][3]), .D4(tw[g][4]),
            .D5(tw[g][5]), .D6(tw[g][6]), .D7(tw[g][7]), .D8(tw[g][8]), .D9(tw[g][9]),
            .PCLK(clk_pix), .FCLK(clk_ser), .RESET(rst)
        );
    end endgenerate
    ELVDS_OBUF u_ob0 (.I(ser[0]), .O(tmds_d_p[0]), .OB(tmds_d_n[0]));
    ELVDS_OBUF u_ob1 (.I(ser[1]), .O(tmds_d_p[1]), .OB(tmds_d_n[1]));
    ELVDS_OBUF u_ob2 (.I(ser[2]), .O(tmds_d_p[2]), .OB(tmds_d_n[2]));
    ELVDS_OBUF u_obc (.I(ser[3]), .O(tmds_clk_p),  .OB(tmds_clk_n));
endmodule

// ============================================================================
// tmds_chan - one TMDS channel: video (8b/10b with DC balance), control, TERC4, guards
// ============================================================================
module tmds_chan #(
    parameter CN = 0
)(
    input  wire       clk,
    input  wire       rst,
    input  wire [2:0] mode,
    input  wire [7:0] vd,
    input  wire [1:0] cd,
    input  wire [3:0] dd,
    output reg  [9:0] q
);
    // ---- video: transition minimization
    wire [3:0] n1d = vd[0] + vd[1] + vd[2] + vd[3] + vd[4] + vd[5] + vd[6] + vd[7];
    wire use_xnor = (n1d > 4'd4) || (n1d == 4'd4 && vd[0] == 1'b0);
    wire [8:0] qm;
    assign qm[0] = vd[0];
    genvar i;
    generate for (i = 1; i < 8; i = i + 1) begin : g_qm
        assign qm[i] = use_xnor ? ~(qm[i-1] ^ vd[i]) : (qm[i-1] ^ vd[i]);
    end endgenerate
    assign qm[8] = ~use_xnor;
    wire [3:0] n1q = qm[0] + qm[1] + qm[2] + qm[3] + qm[4] + qm[5] + qm[6] + qm[7];
    wire [3:0] n0q = 4'd8 - n1q;
    reg  signed [4:0] cnt;                         // accumulated disparity

    // ---- TERC4
    reg [9:0] terc;
    always @(*) begin
        case (dd)
        4'h0: terc = 10'b1010011100; 4'h1: terc = 10'b1001100011;
        4'h2: terc = 10'b1011100100; 4'h3: terc = 10'b1011100010;
        4'h4: terc = 10'b0101110001; 4'h5: terc = 10'b0100011110;
        4'h6: terc = 10'b0110001110; 4'h7: terc = 10'b0100111100;
        4'h8: terc = 10'b1011001100; 4'h9: terc = 10'b0100111001;
        4'hA: terc = 10'b0110011100; 4'hB: terc = 10'b1011000110;
        4'hC: terc = 10'b1010001110; 4'hD: terc = 10'b1001110001;
        4'hE: terc = 10'b0101100011; default: terc = 10'b1011000011;
        endcase
    end
    reg [9:0] ctrl;
    always @(*) begin
        case (cd)
        2'b00: ctrl = 10'b1101010100;
        2'b01: ctrl = 10'b0010101011;
        2'b10: ctrl = 10'b0101010100;
        default: ctrl = 10'b1010101011;
        endcase
    end
    // guards: video (ch0, ch2 = 1011001100; ch1 = 0100110011), island (ch1, ch2 = 0100110011)
    wire [9:0] vguard = (CN == 1) ? 10'b0100110011 : 10'b1011001100;
    wire [9:0] dguard0 = (dd[1:0] == 2'b00) ? 10'b1010001110 :
                         (dd[1:0] == 2'b01) ? 10'b1001110001 :
                         (dd[1:0] == 2'b10) ? 10'b0101100011 : 10'b1011000011;
    wire [9:0] dguard  = (CN == 0) ? dguard0 : 10'b0100110011;

    wire signed [4:0] d10 = $signed({1'b0, n1q}) - $signed({1'b0, n0q});
    always @(posedge clk) begin
        if (rst) begin
            q <= 10'd0; cnt <= 5'sd0;
        end else begin
            case (mode)
            3'd1: begin
                if (cnt == 0 || n1q == n0q) begin
                    q   <= {~qm[8], qm[8], qm[8] ? qm[7:0] : ~qm[7:0]};
                    cnt <= qm[8] ? cnt + d10 : cnt - d10;
                end else if ((cnt > 0 && n1q > n0q) || (cnt < 0 && n0q > n1q)) begin
                    q   <= {1'b1, qm[8], ~qm[7:0]};
                    cnt <= cnt + $signed({3'b000, qm[8], 1'b0}) - d10;
                end else begin
                    q   <= {1'b0, qm[8], qm[7:0]};
                    cnt <= cnt - $signed({3'b000, ~qm[8], 1'b0}) + d10;
                end
            end
            3'd2: begin q <= vguard; cnt <= 5'sd0; end
            3'd3: begin q <= terc;   cnt <= 5'sd0; end
            3'd4: begin q <= dguard; cnt <= 5'sd0; end
            default: begin q <= ctrl; cnt <= 5'sd0; end
            endcase
        end
    end
endmodule
`default_nettype wire
