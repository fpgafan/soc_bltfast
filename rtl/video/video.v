// ============================================================================
// video.v - Controlador de vídeo 640x480@60, framebuffer 8 bpp con paleta
//
//  Dominio sys : registros, DMA de líneas desde la SDRAM (maestro 0), paleta
//  Dominio pix : timing 800x525 a 25,2 MHz, lectura del buffer de línea y
//                de la paleta, salida RGB888 + sincronismos
//
//  Scroll por hardware: cada línea visible y se lee de la fila
//     r = (SCROLL_Y + y) mod WRAP_H              (sin wrap si WRAP_H = 0)
//  del lienzo que empieza en FB_BASE con FB_STRIDE bytes por fila, a partir
//  de la columna SCROLL_X; con WRAP_W = n (n >= 2) la fila se trata como un
//  anillo de 2^n * 256 bytes (scroll horizontal infinito).
//  Los registros se copian al principio de cada cuadro (doble buffer sin
//  cortes) o en cada línea si CTRL.LIVE = 1 (efectos de raster).
//
//  Registros (base 0x8000_2000):
//   +0x00 CTRL      [0] activar, [1] LIVE, [2] HDMI (data islands, audio)
//   +0x04 FB_BASE   dirección en bytes (0x4xxx_xxxx o desplazamiento)
//   +0x08 STRIDE    bytes por fila (múltiplo de 4)
//   +0x0C SCROLL_X  píxeles
//   +0x10 SCROLL_Y  filas
//   +0x14 WRAP_W    [3:0] n: anillo horizontal de 2^n * 256 bytes (0 = no)
//   +0x18 WRAP_H    filas del lienzo para el wrap vertical (0 = no)
//   +0x1C BORDER    índice de color cuando la pantalla está desactivada
//   +0x20 RASTER    línea de la interrupción RASTER
//   +0x24 STATUS    R: [9:0] línea en preparación, [16] vblank, [31:20] cuadros
//   +0x28 PENDING   R: [0] cambio de registros pendiente de aplicar
//   Paleta: 0x8000_3000 + 4*i = 0x00RRGGBB (solo escritura)
// ============================================================================
`default_nettype none
module video (
    input  wire        clk,             // sys
    input  wire        rst,
    input  wire        clk_pix,
    input  wire        rst_pix,
    // registros
    input  wire        sel,
    input  wire        pal_sel,
    input  wire        we,
    input  wire [5:0]  a,
    input  wire [7:0]  pal_a,
    input  wire [31:0] wd,
    output reg  [31:0] rd,
    output reg         irq_vblank,      // pulsos (dominio sys)
    output reg         irq_raster,
    // maestro SDRAM (lectura)
    output reg         m_req,
    output reg  [22:2] m_addr,
    output reg  [3:0]  m_len,
    input  wire        m_ack,
    input  wire [31:0] m_rdata,
    input  wire        m_rvalid,
    // salida (dominio pix)
    output reg  [23:0] rgb,
    output reg         hsync,
    output reg         vsync,
    output reg         de,
    output reg  [9:0]  pix_hcount,      // alineados con rgb/de
    output reg  [9:0]  pix_vcount,
    output reg         hdmi_mode        // dominio sys (cuasi estático)
);
    // =====================================================================
    // Registros (sys)
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
    // copia activa (se usa al preparar las líneas)
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

    // petición de línea: al empezar cada línea vc se prepara la línea vc+1
    reg        lreq_tgl;
    reg [9:0]  lreq_line;               // estable mientras el toggle viaja
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
                // línea a preparar: vc+1 (o 0 durante la última línea)
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
    // Cruce pix -> sys
    // =====================================================================
    reg [2:0] lreq_s, vbl_s;
    always @(posedge clk) begin
        lreq_s <= {lreq_s[1:0], lreq_tgl};
        vbl_s  <= {vbl_s[1:0], vbl_tgl};
    end
    wire lreq_ev = lreq_s[2] ^ lreq_s[1];
    wire vbl_ev  = vbl_s[2] ^ vbl_s[1];

    // =====================================================================
    // Buffer de línea: 2 x 256 palabras (sys escribe, pix lee)
    // =====================================================================
    reg [31:0] lbuf [0:511];
    reg        lb_we;
    reg [8:0]  lb_wa;
    reg [31:0] lb_wd;
    always @(posedge clk) if (lb_we) lbuf[lb_wa] <= lb_wd;

    // =====================================================================
    // DMA de líneas (sys)
    // =====================================================================
    localparam D_IDLE = 3'd0, D_REQ = 3'd1, D_ROW = 3'd2, D_DATA = 3'd3, D_ROW2 = 3'd4;
    reg [2:0]  dst;
    reg [11:0] f_rsum;
    reg        lpend;                   // petición de línea pendiente
    reg [9:0]  lpend_line;
    reg        f_half;                  // mitad del buffer (línea & 1)
    reg [9:0]  f_line;
    reg [10:0] f_row;                   // fila del lienzo de la línea
    reg [22:0] f_rowaddr;               // base + fila*stride
    reg [12:0] f_col;                   // columna (bytes) de la palabra siguiente
    reg [7:0]  f_left;                  // palabras que faltan
    reg [7:0]  f_widx;                  // índice de escritura en el buffer
    reg [4:0]  f_burst;                 // palabras de la ráfaga en curso
    reg [1:0]  f_fine [0:1];            // desplazamiento fino por mitad
    reg        f_blank [0:1];           // línea en negro (pantalla desactivada)
    reg [7:0]  f_bcol [0:1];

    // longitud de la ráfaga: hasta 16 palabras, sin cruzar 1 KB ni el wrap.
    // Se calcula en dos ciclos: D_DATA alterna entre preparar (f_prep) y pedir.
    reg  [12:0] wrap_m;                 // máscara del anillo (todo unos si no hay wrap)
    reg  [12:0] wrap_b;                 // tamaño del anillo en bytes
    reg         f_prep;
    reg  [22:0] wa_q;                   // dirección en bytes de la ráfaga
    reg  [12:0] colm_q;
    reg  [8:0]  to_row_q;               // palabras hasta el límite de 1 KB (1..256)
    reg  [10:0] to_wrap_q;              // palabras hasta el final del anillo
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
            // -------------------------------------------- escritura de registros
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

            // -------------------------------------------- nueva línea
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
                // copiar registros: al empezar el cuadro, o en cada línea en modo LIVE
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
                // fila del lienzo para esta línea (registros c_* ya copiados)
                // fila = (SCROLL_Y + línea) mod WRAP_H, en dos pasos (D_REQ y D_ROW)
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
            D_ROW2: dst <= D_DATA;          // espera a f_rowaddr (multiplicación)
            D_DATA: begin
                if (f_burst == 5'd0 && !m_req) begin
                    if (f_left == 8'd0)
                        dst <= D_IDLE;
                    else if (f_prep) begin
                        // ciclo 1: dirección y distancias a los límites
                        wa_q      <= wa_byte;
                        colm_q    <= col_m;
                        to_row_q  <= 9'd256 - {1'b0, wa_byte[9:2]};
                        to_wrap_q <= (wrap_b - col_m) >> 2;
                        f_prep    <= 1'b0;
                    end else begin
                        // ciclo 2: petición
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

    // dirección de la fila (multiplicación incremental evitada: DSP)
    always @(posedge clk) f_rowaddr <= c_base + f_row * c_stride;

    always @(posedge clk) hdmi_mode <= r_hdmi;

    // lectura de registros
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
    // Paleta: 256 x 24 (sys escribe, pix lee)
    // =====================================================================
    reg [23:0] pal [0:255];
    integer pi;
    initial for (pi = 0; pi < 256; pi = pi + 1) pal[pi] = {pi[7:0], pi[7:0], pi[7:0]};
    always @(posedge clk) if (pal_sel & we) pal[pal_a] <= wd[23:0];

    // =====================================================================
    // Salida de píxeles (pix)
    //   etapa 0: hc/vc -> dirección del buffer de línea
    //   etapa 1: palabra leída -> byte
    //   etapa 2: paleta -> RGB
    // =====================================================================
    // las variables f_fine/f_blank de la mitad que se muestra son estables
    // durante toda la línea (se escribieron una línea antes)
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
