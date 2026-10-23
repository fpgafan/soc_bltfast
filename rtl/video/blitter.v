// ============================================================================
// blitter.v - Motor de dibujo 2D por hardware (8 bpp), maestro 3 de la SDRAM
//
// Operaciones (CMD[3:0]):
//   0 FILL    rellena el rectángulo DST_XY/SIZE con COLOR.fg
//   1 BLIT    copia desde SRC con escalado separable y espejo:
//             para el píxel (i, j) del rectángulo destino se lee el texel
//             (U0 + i*DU, V0 + j*DV) (16.16 con signo, relativo a SRC_ADDR).
//             Copia 1:1 -> U0 = V0 = 0, DU = DV = 0x10000; espejo X -> U0 =
//             (w-1)<<16, DU = -0x10000; escalado x2 -> DU = 0x8000...
//             Si |DU| <= 1.0 genera 4 píxeles por ciclo; si no, 1.
//   2 EXPAND  como BLIT pero el origen es de 1 bit por píxel (MSB primero;
//             U en bits): bit 1 -> fg, bit 0 -> bg (o transparente)
//   3 LINE    línea de DST_XY a SIZE (x1 | y1 << 16) con COLOR.fg
//   Flags: CMD[4] transparencia (texel == KEY no se escribe), CMD[5] fondo
//   transparente en EXPAND, CMD[6] sumar PALOFF a los texels.
//   Todo se recorta contra CLIP (x0,y0 incluidos, x1,y1 excluidos).
//
// Registros (base 0x8000_4000; se copian a la cola al escribir CMD):
//   +0x00 STATUS   R: [0] ocupado, [1] cola llena, [12:8] comandos en cola,
//                     [31:16] comandos terminados (contador)
//   +0x04 DST_BASE  dirección en bytes de la superficie destino
//   +0x08 DST_STRIDE
//   +0x0C CLIP0     x0 | y0 << 16
//   +0x10 CLIP1     x1 | y1 << 16
//   +0x14 SRC_ADDR  dirección en bytes del texel (0,0) de origen
//   +0x18 SRC_STRIDE
//   +0x1C DST_XY    x | y << 16 (con signo)
//   +0x20 SIZE      w | h << 16 (LINE: x1 | y1 << 16)
//   +0x24 COLOR     fg | bg << 8 | key << 16 | paloff << 24
//   +0x28 U0        +0x2C V0      +0x30 DU      +0x34 DV
//   +0x38 CMD       W: encola el comando (el bus espera si la cola está llena)
//   +0x3C IRQ       R/W [0] interrupción al vaciarse la cola
//   Límite: la fila de origen leída (span de U) no puede superar 2048 bytes.
// ============================================================================
`default_nettype none
module blitter (
    input  wire        clk,
    input  wire        rst,
    // registros (el ack lo da el módulo: puede esperar con la cola llena)
    input  wire        sel,
    input  wire        we,
    input  wire [5:0]  a,
    input  wire [31:0] wd,
    output reg  [31:0] rd,
    output reg         ack,
    output reg         irq,
    // maestro SDRAM
    output reg         m_req,
    output reg         m_we,
    output reg  [22:2] m_addr,
    output reg  [3:0]  m_len,
    input  wire        m_ack,
    output wire [31:0] m_wdata,
    output wire [3:0]  m_wmask,
    input  wire        m_wnext,
    input  wire [31:0] m_rdata,
    input  wire        m_rvalid
);
    // =====================================================================
    // Registros de preparación y cola de comandos (16 palabras por entrada)
    // =====================================================================
    reg [31:0] stg [0:13];          // índices 1..13 = registros +0x04..+0x34
    reg        irq_en;
    reg [15:0] done_cnt;

    reg [31:0] cq [0:511];          // 32 entradas x 16 palabras
    reg [4:0]  cq_wp, cq_rp;
    reg [5:0]  cq_n;
    reg        cp_busy;             // copiando los registros a la cola (el bus espera)
    reg [3:0]  cp_i;
    reg [31:0] cmd_w;
    reg        cq_we;
    reg [8:0]  cq_wa;
    reg [31:0] cq_wd;
    reg [8:0]  cq_ra;
    reg [31:0] cq_q;
    always @(posedge clk) begin
        if (cq_we) cq[cq_wa] <= cq_wd;
        cq_q <= cq[cq_ra];
    end

    wire cq_full = (cq_n == 6'd32);
    reg  pend_cmd;                  // escritura a CMD esperando sitio
    reg  [31:0] pend_wd;
    reg  eng_busy;
    wire cq_pop;

    integer k;
    always @(posedge clk) begin
        ack   <= 1'b0;
        cq_we <= 1'b0;
        if (rst) begin
            cq_wp <= 5'd0; cp_busy <= 1'b0; pend_cmd <= 1'b0; irq_en <= 1'b0;
            for (k = 0; k < 14; k = k + 1) stg[k] <= 32'd0;
            stg[2] <= 32'd640; stg[4] <= {16'd480, 16'd640};
            stg[12] <= 32'h0001_0000; stg[13] <= 32'h0001_0000;
        end else begin
            if (sel && !ack && !pend_cmd) begin
                if (we && a[5:2] == 4'hE) begin
                    // CMD: esperar a que haya sitio y a que acabe la copia anterior
                    pend_cmd <= 1'b1;
                    pend_wd  <= wd;
                end else begin
                    if (we) begin
                        if (a[5:2] >= 4'h1 && a[5:2] <= 4'hD) stg[a[5:2]] <= wd;
                        if (a[5:2] == 4'hF) irq_en <= wd[0];
                    end
                    ack <= 1'b1;
                end
            end
            if (pend_cmd && !cp_busy && !cq_full) begin
                cmd_w    <= pend_wd;
                cp_busy  <= 1'b1;
                cp_i     <= 4'd0;
            end
            if (cp_busy) begin
                cq_we <= 1'b1;
                cq_wa <= {cq_wp, cp_i};
                cq_wd <= (cp_i == 4'd0) ? cmd_w : stg[cp_i];
                cp_i  <= cp_i + 4'd1;
                if (cp_i == 4'd13) begin
                    cp_busy  <= 1'b0;
                    cq_wp    <= cq_wp + 5'd1;
                    pend_cmd <= 1'b0;
                    ack      <= 1'b1;          // la CPU sigue cuando el comando está en la cola
                end
            end
        end
    end

    // lectura de registros
    always @(posedge clk) begin
        case (a[5:2])
        4'h0:    rd <= {done_cnt, 2'd0, cq_n, 6'd0, cq_full, eng_busy | (cq_n != 6'd0) | cp_busy | pend_cmd};
        4'hF:    rd <= {31'd0, irq_en};
        4'hE:    rd <= 32'd0;
        default: rd <= stg[a[5:2]];
        endcase
    end

    // =====================================================================
    // Multiplicador compartido (con signo): p = ma * mb, 3 ciclos
    //   ma: 18 bits con signo, mb: 32 bits con signo -> p[31:0]
    // =====================================================================
    reg  signed [17:0] ma;
    reg  [31:0]        mb;
    reg  signed [17:0] ma1;
    reg  signed [16:0] mbl1;            // parte baja sin signo (bit 16 = 0)
    reg  signed [16:0] mbh1;            // parte alta con signo
    reg  signed [34:0] ppl, pph;
    reg  [31:0]        mp;
    always @(posedge clk) begin
        ma1  <= ma;
        mbl1 <= {1'b0, mb[15:0]};
        mbh1 <= mb[31:16];
        ppl  <= ma1 * mbl1;
        pph  <= ma1 * mbh1;
        mp   <= ppl[31:0] + {pph[15:0], 16'd0};
    end

    // =====================================================================
    // Motor
    // =====================================================================
    // campos del comando en curso
    reg [3:0]  op;
    reg        f_tr, f_bgtr, f_pal;
    reg [22:0] c_dbase, c_src;
    reg [15:0] c_dstride, c_sstride;
    reg signed [15:0] c_cx0, c_cy0, c_cx1, c_cy1, c_dx, c_dy, c_w, c_h;
    reg [7:0]  c_fg, c_bg, c_key, c_pal;
    reg signed [31:0] c_u0, c_v0, c_du, c_dv;

    localparam E_IDLE = 5'd0, E_LOAD = 5'd1, E_CLIP = 5'd2, E_M1 = 5'd3, E_M2 = 5'd4,
               E_M3 = 5'd5, E_M4 = 5'd6, E_ROW = 5'd7, E_ROWM = 5'd8, E_RD = 5'd9,
               E_GEN = 5'd10, E_GWAIT = 5'd11, E_WR = 5'd12, E_NEXT = 5'd13,
               E_DONE = 5'd14, E_LINE = 5'd15, E_LPIX = 5'd16, E_LWAIT = 5'd17,
               E_RANGE = 5'd18, E_WAITM = 5'd19, E_WR0 = 5'd20, E_WR1 = 5'd21,
               E_LINIT = 5'd22, E_LSTEP = 5'd23;
    reg [4:0]  es, es_ret;
    reg [1:0]  mwait;
    reg [4:0]  ld_i;

    reg signed [16:0] vx0, vx1, vy0, vy1;
    reg [15:0] vw;
    reg signed [15:0] jrow;              // fila actual (coordenada destino)
    reg signed [31:0] u_st, u_en, vcur;
    reg signed [15:0] s_lo, s_hi;        // texels (o bytes en EXPAND) extremos
    reg [22:0] drow;                      // dirección del primer píxel visible de la fila
    reg [22:0] srow;                      // dirección de la fila de origen
    // camino rápido (4 píxeles/ciclo): |DU| <= 1.0 -> los 4 texels caen en 4 bytes seguidos
    wire fast = (c_du <= 32'sh0001_0000) && (c_du >= -32'sh0001_0000);

    // ---------------------------------------------------------------- buffer de origen (RB)
    reg [7:0]  rb0 [0:511], rb1 [0:511], rb2 [0:511], rb3 [0:511];
    reg        rb_we;
    reg [8:0]  rb_wa;
    reg [31:0] rb_wd;
    reg [8:0]  rb_ra0, rb_ra1, rb_ra2, rb_ra3;
    reg [7:0]  rb_q0, rb_q1, rb_q2, rb_q3;
    always @(posedge clk) begin
        if (rb_we) begin
            rb0[rb_wa] <= rb_wd[7:0];   rb1[rb_wa] <= rb_wd[15:8];
            rb2[rb_wa] <= rb_wd[23:16]; rb3[rb_wa] <= rb_wd[31:24];
        end
        rb_q0 <= rb0[rb_ra0]; rb_q1 <= rb1[rb_ra1];
        rb_q2 <= rb2[rb_ra2]; rb_q3 <= rb3[rb_ra3];
    end

    // ---------------------------------------------------------------- buffer de salida (OB)
    reg [35:0] ob [0:511];
    reg        ob_we;
    reg [8:0]  ob_wa;
    reg [35:0] ob_wd;
    wire [8:0] ob_ra;
    reg [35:0] ob_q;
    always @(posedge clk) begin
        if (ob_we) ob[ob_wa] <= ob_wd;
        ob_q <= ob[ob_ra];
    end

    // ---------------------------------------------------------------- lectura de la fila de origen
    reg [22:2] rd_w;                     // siguiente palabra a pedir
    reg [9:0]  rd_left;                  // palabras que faltan por pedir
    reg [9:0]  rd_got;                   // palabras recibidas (índice en RB)
    reg [9:0]  rd_tot;
    reg [4:0]  rd_out;                   // palabras pendientes de la ráfaga en curso
    reg [4:0]  bl_q;                     // longitud de la próxima ráfaga (precalculada)
    reg        bl_ok;
    reg        row_last;
    reg [1:0]  s_bias;                   // (dirección del primer byte) & 3

    // ---------------------------------------------------------------- generación
    reg [9:0]  g_nw;                     // palabras destino de la fila
    reg [9:0]  g_w;                      // palabra en curso
    reg [1:0]  g_k;                      // píxel dentro de la palabra (modo lento)
    reg signed [31:0] g_u;               // U del píxel 0 de la palabra (rápido) / del píxel (lento)
    reg signed [16:0] g_i;               // índice del píxel 0 de la palabra en curso
    reg        g_run;
    reg signed [31:0] du2, du3, du4;
    // etapa 1
    reg        p1_v, p1_last;
    reg signed [31:0] p1_u0, p1_u1, p1_u2, p1_u3;
    reg [3:0]  p1_m;                     // píxeles dentro del rango
    reg [8:0]  p1_w;
    reg [1:0]  p1_k;
    // etapa 2
    reg        p2_v, p2_last;
    reg signed [15:0] p2_s0, p2_s1, p2_s2, p2_s3;   // índices de byte en RB
    reg [2:0]  p2_b0, p2_b1, p2_b2, p2_b3;           // bit (EXPAND)
    reg [3:0]  p2_m;
    reg [8:0]  p2_w;
    reg [1:0]  p2_k;
    // etapa 3 (lectura de RB)
    reg        p3_v, p3_last;
    reg [1:0]  p3_l0, p3_l1, p3_l2, p3_l3;
    reg [2:0]  p3_b0, p3_b1, p3_b2, p3_b3;
    reg [3:0]  p3_m;
    reg [8:0]  p3_w;
    reg [1:0]  p3_k;
    // etapa 4 (dato de RB disponible)
    reg        p4_v, p4_last;
    reg [1:0]  p4_l0, p4_l1, p4_l2, p4_l3;
    reg [2:0]  p4_b0, p4_b1, p4_b2, p4_b3;
    reg [3:0]  p4_m;
    reg [8:0]  p4_w;
    reg [1:0]  p4_k;
    // etapa 5
    reg        p5_v, p5_last;
    reg [3:0]  p5_m;
    reg [8:0]  p5_w;
    reg [1:0]  p5_k;
    reg [8:0]  p5_x0, p5_x1, p5_x2, p5_x3;
    // empaquetado
    reg [31:0] acc_d;
    reg [3:0]  acc_m;

    // índice de byte en RB a partir de U
    wire signed [15:0] rb_off = {14'd0, s_bias} - s_lo;
    function signed [15:0] sidx(input signed [31:0] u, input e);
        sidx = e ? ($signed(u[31:16]) >>> 3) : $signed(u[31:16]);
    endfunction

    // texel -> píxel de salida
    function [8:0] xform(input [7:0] t, input bit_v, input is_exp);
        reg [7:0] c;
        reg       tr;
        begin
            if (is_exp) begin
                c  = bit_v ? c_fg : c_bg;
                tr = ~bit_v & f_bgtr;
            end else begin
                c  = f_pal ? t + c_pal : t;
                tr = f_tr & (t == c_key);
            end
            xform = {~tr, c};
        end
    endfunction

    wire [7:0] lane_q [0:3];
    assign lane_q[0] = rb_q0; assign lane_q[1] = rb_q1; assign lane_q[2] = rb_q2; assign lane_q[3] = rb_q3;

    // ---------------------------------------------------------------- escritura de la fila
    reg [22:2] wr_w;
    reg [9:0]  wr_left, wr_idx;
    reg [4:0]  wr_out;
    reg [35:0] wreg;                     // palabra que se está escribiendo (= OB[wr_idx])
    // prelectura: ob_q siempre contiene OB[wr_idx + 1] (o OB[0] en E_WR0 -> E_WR1)
    assign m_wdata = wreg[31:0];
    assign m_wmask = wreg[35:32];

    // ---------------------------------------------------------------- líneas
    reg signed [16:0] lx, ly, lx1, ly1, ldx, ldy, lerr;
    reg               lsx, lsy;
    reg [22:0]        laddr;

    assign cq_pop = (es == E_LOAD) && (ld_i == 5'd15);
    assign ob_ra  = (es == E_WR0) ? 9'd0 : m_wnext ? wr_idx[8:0] + 9'd2 : wr_idx[8:0] + 9'd1;

    wire signed [16:0] c_dx17 = c_dx, c_dy17 = c_dy;

    // burst: hasta 16 palabras sin cruzar 1 KB
    function [4:0] blen(input [22:2] wa, input [9:0] left);
        reg [8:0] to_row;
        begin
            to_row = 9'd256 - {1'b0, wa[9:2]};
            blen = (left > 10'd16) ? 5'd16 : left[4:0];
            if ({4'd0, to_row} < {5'd0, blen}) blen = to_row[4:0];
        end
    endfunction

    always @(posedge clk) begin
        rb_we <= 1'b0;
        ob_we <= 1'b0;
        irq   <= 1'b0;
        if (rst) begin
            es <= E_IDLE;
            cq_rp <= 5'd0; cq_n <= 6'd0;
            m_req <= 1'b0;
            eng_busy <= 1'b0;
            done_cnt <= 16'd0;
            g_run <= 1'b0; p1_v <= 1'b0; p2_v <= 1'b0; p3_v <= 1'b0; p4_v <= 1'b0; p5_v <= 1'b0;
        end else begin
            cq_n <= cq_n + ((cp_busy && cp_i == 4'd13) ? 6'd1 : 6'd0) - (cq_pop ? 6'd1 : 6'd0);
            if (m_ack) m_req <= 1'b0;

            case (es)
            // ------------------------------------------------------------ cola
            E_IDLE: begin
                eng_busy <= 1'b0;
                if (cq_n != 6'd0) begin
                    eng_busy <= 1'b1;
                    ld_i  <= 5'd0;
                    cq_ra <= {cq_rp, 4'd0};
                    es    <= E_LOAD;
                end
            end
            E_LOAD: begin
                // cq_q tiene la palabra ld_i-1 (latencia 1)
                cq_ra <= {cq_rp, ld_i[3:0] + 4'd1};
                ld_i  <= ld_i + 5'd1;
                case (ld_i)
                5'd1:  begin op <= cq_q[3:0]; f_tr <= cq_q[4]; f_bgtr <= cq_q[5]; f_pal <= cq_q[6]; end
                5'd2:  c_dbase   <= cq_q[22:0];
                5'd3:  c_dstride <= cq_q[15:0];
                5'd4:  begin c_cx0 <= cq_q[15:0]; c_cy0 <= cq_q[31:16]; end
                5'd5:  begin c_cx1 <= cq_q[15:0]; c_cy1 <= cq_q[31:16]; end
                5'd6:  c_src     <= cq_q[22:0];
                5'd7:  c_sstride <= cq_q[15:0];
                5'd8:  begin c_dx <= cq_q[15:0]; c_dy <= cq_q[31:16]; end
                5'd9:  begin c_w  <= cq_q[15:0]; c_h  <= cq_q[31:16]; end
                5'd10: begin c_fg <= cq_q[7:0]; c_bg <= cq_q[15:8]; c_key <= cq_q[23:16]; c_pal <= cq_q[31:24]; end
                5'd11: c_u0 <= cq_q;
                5'd12: c_v0 <= cq_q;
                5'd13: c_du <= cq_q;
                5'd14: c_dv <= cq_q;
                default: ;
                endcase
                if (ld_i == 5'd15) begin
                    cq_rp <= cq_rp + 5'd1;
                    es    <= (op == 4'd3) ? E_LINE : E_CLIP;
                end
            end
            // ------------------------------------------------------------ recorte
            E_CLIP: begin
                vx0 <= (c_dx17 > c_cx0) ? c_dx17 : c_cx0;
                vy0 <= (c_dy17 > c_cy0) ? c_dy17 : c_cy0;
                vx1 <= (c_dx17 + c_w < c_cx1) ? c_dx17 + c_w : c_cx1;
                vy1 <= (c_dy17 + c_h < c_cy1) ? c_dy17 + c_h : c_cy1;
                es  <= E_M1;
            end
            E_M1: begin
                if (vx0 >= vx1 || vy0 >= vy1)
                    es <= E_DONE;
                else begin
                    vw   <= vx1 - vx0;
                    jrow <= vy0;
                    ma <= vx0 - c_dx17; mb <= c_du;       // (vx0 - dx) * DU
                    mwait <= 2'd0; es_ret <= E_M2; es <= E_WAITM;
                end
            end
            E_M2: begin
                u_st <= c_u0 + mp;
                ma <= vw - 16'd1; mb <= c_du;            // (vw - 1) * DU
                mwait <= 2'd0; es_ret <= E_M3; es <= E_WAITM;
            end
            E_M3: begin
                u_en <= u_st + mp;
                ma <= vy0 - c_dy17; mb <= c_dv;          // (vy0 - dy) * DV
                mwait <= 2'd0; es_ret <= E_M4; es <= E_WAITM;
            end
            E_M4: begin
                vcur <= c_v0 + mp;
                ma <= vy0; mb <= {16'd0, c_dstride};     // vy0 * DSTRIDE
                mwait <= 2'd0; es_ret <= E_RANGE; es <= E_WAITM;
            end
            E_RANGE: begin
                drow <= c_dbase + mp[22:0] + {{6{vx0[16]}}, vx0};
                // extremos del span de U (en bytes de RB)
                s_lo <= (u_st < u_en) ? sidx(u_st, op == 4'd2) : sidx(u_en, op == 4'd2);
                s_hi <= (u_st < u_en) ? sidx(u_en, op == 4'd2) : sidx(u_st, op == 4'd2);
                du2 <= c_du <<< 1;
                du3 <= (c_du <<< 1) + c_du;
                du4 <= c_du <<< 2;
                es  <= E_ROW;
            end
            E_WAITM: begin
                mwait <= mwait + 2'd1;
                if (mwait == 2'd3) es <= es_ret;
            end
            // ------------------------------------------------------------ filas
            E_ROW: begin
                row_last <= (jrow + 16'sd1 >= vy1);
                if (op == 4'd0) begin
                    es <= E_GEN;
                    g_run <= 1'b0;
                end else begin
                    ma <= $signed(vcur[31:16]); mb <= {16'd0, c_sstride};   // fila de origen * stride
                    mwait <= 2'd0; es_ret <= E_ROWM; es <= E_WAITM;
                end
            end
            E_ROWM: begin
                // primera y última palabra de la fila de origen
                begin : rr
                    reg [22:0] lo_a, hi_a;
                    lo_a = c_src + mp[22:0] + {{7{s_lo[15]}}, s_lo};
                    hi_a = c_src + mp[22:0] + {{7{s_hi[15]}}, s_hi};
                    srow    <= c_src + mp[22:0];
                    s_bias  <= lo_a[1:0];
                    rd_w    <= lo_a[22:2];
                    rd_left <= hi_a[22:2] - lo_a[22:2] + 10'd1;
                    rd_tot  <= hi_a[22:2] - lo_a[22:2] + 10'd1;
                end
                rd_got <= 10'd0;
                rd_out <= 5'd0;
                bl_ok  <= 1'b0;
                es     <= E_RD;
            end
            E_RD: begin
                if (!m_req && rd_out == 5'd0) begin
                    if (rd_left == 10'd0) begin
                        if (rd_got == rd_tot) begin
                            es <= E_GEN;
                            g_run <= 1'b0;
                        end
                    end else if (!bl_ok) begin
                        bl_q  <= blen(rd_w, rd_left);
                        bl_ok <= 1'b1;
                    end else begin
                        m_req   <= 1'b1;
                        m_we    <= 1'b0;
                        m_addr  <= rd_w;
                        m_len   <= bl_q - 5'd1;
                        rd_out  <= bl_q;
                        rd_w    <= rd_w + {16'd0, bl_q};
                        rd_left <= rd_left - {5'd0, bl_q};
                        bl_ok   <= 1'b0;
                    end
                end
                if (m_rvalid) begin
                    rb_we  <= 1'b1;
                    rb_wa  <= rd_got[8:0];
                    rb_wd  <= m_rdata;
                    rd_got <= rd_got + 10'd1;
                    rd_out <= rd_out - 5'd1;
                end
            end
            // ------------------------------------------------------------ generación
            E_GEN: begin
                if (!g_run) begin
                    // arranque de la fila
                    g_run <= 1'b1;
                    g_nw  <= ((drow + {7'd0, vw} - 23'd1) >> 2) - (drow >> 2) + 23'd1;
                    g_w   <= 10'd0;
                    g_k   <= 2'd0;
                    g_i   <= -$signed({15'd0, drow[1:0]});
                    // U del píxel 0 de la primera palabra = u_st - (drow & 3) * DU
                    g_u   <= u_st - (drow[1] ? du2 : 32'sd0) - (drow[0] ? c_du : 32'sd0);
                    acc_m <= 4'd0;
                end else if (g_w != g_nw) begin
                    // emitir una ranura
                    p1_v    <= 1'b1;
                    p1_w    <= g_w[8:0];
                    if (fast || op == 4'd0) begin
                        p1_u0 <= g_u; p1_u1 <= g_u + c_du; p1_u2 <= g_u + du2; p1_u3 <= g_u + du3;
                        p1_m  <= { (g_i + 17'sd3 >= 0) && (g_i + 17'sd3 < $signed({1'b0, vw})),
                                   (g_i + 17'sd2 >= 0) && (g_i + 17'sd2 < $signed({1'b0, vw})),
                                   (g_i + 17'sd1 >= 0) && (g_i + 17'sd1 < $signed({1'b0, vw})),
                                   (g_i >= 0) && (g_i < $signed({1'b0, vw})) };
                        p1_k    <= 2'd3;
                        p1_last <= 1'b1;
                        g_u <= g_u + du4;
                        g_i <= g_i + 17'sd4;
                        g_w <= g_w + 10'd1;
                    end else begin
                        // modo lento: un píxel por ciclo
                        p1_u0 <= g_u; p1_u1 <= g_u; p1_u2 <= g_u; p1_u3 <= g_u;
                        p1_m  <= ((g_i + $signed({15'd0, g_k}) >= 0) &&
                                  (g_i + $signed({15'd0, g_k}) < $signed({1'b0, vw}))) ? (4'b0001 << g_k) : 4'b0000;
                        p1_k    <= g_k;
                        p1_last <= (g_k == 2'd3);
                        g_u <= g_u + c_du;
                        g_k <= g_k + 2'd1;
                        if (g_k == 2'd3) begin
                            g_i <= g_i + 17'sd4;
                            g_w <= g_w + 10'd1;
                        end
                    end
                end else begin
                    p1_v <= 1'b0;
                    es   <= E_GWAIT;
                end
            end
            E_GWAIT: begin
                p1_v <= 1'b0;
                if (!p1_v && !p2_v && !p3_v && !p4_v && !p5_v && !ob_we) begin
                    wr_w    <= drow[22:2];
                    wr_left <= g_nw;
                    wr_idx  <= 10'd0;
                    wr_out  <= 5'd0;
                    es      <= E_WR0;
                end
            end
            E_WR0: es <= E_WR1;              // se presenta la dirección 0
            E_WR1: begin                     // ob_q = OB[0]
                wreg  <= ob_q;
                bl_ok <= 1'b0;
                es    <= E_WR;
            end
            // ------------------------------------------------------------ escritura
            E_WR: begin
                if (!m_req && wr_out == 5'd0) begin
                    if (wr_left == 10'd0)
                        es <= E_NEXT;
                    else if (!bl_ok) begin
                        bl_q  <= blen(wr_w, wr_left);
                        bl_ok <= 1'b1;
                    end else begin
                        m_req   <= 1'b1;
                        m_we    <= 1'b1;
                        m_addr  <= wr_w;
                        m_len   <= bl_q - 5'd1;
                        wr_out  <= bl_q;
                        wr_w    <= wr_w + {16'd0, bl_q};
                        wr_left <= wr_left - {5'd0, bl_q};
                        bl_ok   <= 1'b0;
                    end
                end
                if (m_wnext) begin
                    wreg   <= ob_q;                 // OB[wr_idx + 1]
                    wr_idx <= wr_idx + 10'd1;
                    wr_out <= wr_out - 5'd1;
                end
            end
            E_NEXT: begin
                if (row_last)
                    es <= E_DONE;
                else begin
                    jrow <= jrow + 16'sd1;
                    vcur <= vcur + c_dv;
                    drow <= drow + {7'd0, c_dstride};
                    es   <= E_ROW;
                end
            end
            E_DONE: begin
                done_cnt <= done_cnt + 16'd1;
                if (irq_en && cq_n == 6'd0) irq <= 1'b1;
                es <= E_IDLE;
            end
            // ------------------------------------------------------------ líneas (Bresenham)
            E_LINE: begin
                lx  <= c_dx; ly <= c_dy; lx1 <= c_w; ly1 <= c_h;
                ldx <= (c_w > c_dx) ? c_w - c_dx : c_dx - c_w;              //  |dx|
                ldy <= (c_h > c_dy) ? c_dy - c_h : c_h - c_dy;              // -|dy|
                lsx <= c_w > c_dx;
                lsy <= c_h > c_dy;
                ma  <= c_dy; mb <= {16'd0, c_dstride};
                mwait <= 2'd0; es_ret <= E_LINIT; es <= E_WAITM;
            end
            E_LINIT: begin
                laddr <= c_dbase + mp[22:0] + {{7{c_dx[15]}}, c_dx};
                lerr  <= ldx + ldy;
                es    <= E_LPIX;
            end
            E_LPIX: begin
                if (lx >= c_cx0 && lx < c_cx1 && ly >= c_cy0 && ly < c_cy1) begin
                    m_req  <= 1'b1;
                    m_we   <= 1'b1;
                    m_addr <= laddr[22:2];
                    m_len  <= 4'd0;
                    wreg   <= {4'b0001 << laddr[1:0], {4{c_fg}}};
                    es     <= E_LWAIT;
                end else
                    es <= E_LSTEP;
            end
            E_LWAIT: if (m_wnext) es <= E_LSTEP;
            E_LSTEP: begin
                if (lx == lx1 && ly == ly1)
                    es <= E_DONE;
                else begin : bres
                    reg signed [17:0] e2;
                    reg signed [16:0] ne;
                    reg [22:0] na;
                    e2 = $signed({lerr, 1'b0});
                    ne = lerr;
                    na = laddr;
                    if (e2 >= $signed({ldy[16], ldy})) begin
                        ne = ne + ldy;
                        lx <= lsx ? lx + 17'sd1 : lx - 17'sd1;
                        na = lsx ? na + 23'd1 : na - 23'd1;
                    end
                    if (e2 <= $signed({ldx[16], ldx})) begin
                        ne = ne + ldx;
                        ly <= lsy ? ly + 17'sd1 : ly - 17'sd1;
                        na = lsy ? na + {7'd0, c_dstride} : na - {7'd0, c_dstride};
                    end
                    lerr  <= ne;
                    laddr <= na;
                    es    <= E_LPIX;
                end
            end
            default: es <= E_IDLE;
            endcase

            // ---------------------------------------------------------------- tubería de generación
            // etapa 2: índices de byte en RB y direcciones por carril
            p2_v <= p1_v; p2_last <= p1_last; p2_m <= p1_m; p2_w <= p1_w; p2_k <= p1_k;
            p2_s0 <= sidx(p1_u0, op == 4'd2) + rb_off;
            p2_s1 <= sidx(p1_u1, op == 4'd2) + rb_off;
            p2_s2 <= sidx(p1_u2, op == 4'd2) + rb_off;
            p2_s3 <= sidx(p1_u3, op == 4'd2) + rb_off;
            p2_b0 <= p1_u0[18:16]; p2_b1 <= p1_u1[18:16]; p2_b2 <= p1_u2[18:16]; p2_b3 <= p1_u3[18:16];
            // etapa 3: lectura de RB (dirección de cada carril dentro de la ventana de 4 bytes)
            p3_v <= p2_v; p3_last <= p2_last; p3_m <= p2_m; p3_w <= p2_w; p3_k <= p2_k;
            p3_l0 <= p2_s0[1:0]; p3_l1 <= p2_s1[1:0]; p3_l2 <= p2_s2[1:0]; p3_l3 <= p2_s3[1:0];
            p3_b0 <= p2_b0; p3_b1 <= p2_b1; p3_b2 <= p2_b2; p3_b3 <= p2_b3;
            begin : lanes
                // ventana de 4 bytes [smin, smin+3]: cada carril lee el único byte suyo
                reg signed [15:0] smin, t0, t1, t2, t3;
                smin = (p2_s0 < p2_s3) ? p2_s0 : p2_s3;
                t0 = smin + {14'd0, 2'd0 - smin[1:0]};
                t1 = smin + {14'd0, 2'd1 - smin[1:0]};
                t2 = smin + {14'd0, 2'd2 - smin[1:0]};
                t3 = smin + {14'd0, 2'd3 - smin[1:0]};
                rb_ra0 <= t0[10:2]; rb_ra1 <= t1[10:2]; rb_ra2 <= t2[10:2]; rb_ra3 <= t3[10:2];
            end
            p4_v <= p3_v; p4_last <= p3_last; p4_m <= p3_m; p4_w <= p3_w; p4_k <= p3_k;
            p4_l0 <= p3_l0; p4_l1 <= p3_l1; p4_l2 <= p3_l2; p4_l3 <= p3_l3;
            p4_b0 <= p3_b0; p4_b1 <= p3_b1; p4_b2 <= p3_b2; p4_b3 <= p3_b3;
            // etapa 5: texels -> píxeles (transformación)
            p5_v <= p4_v; p5_last <= p4_last; p5_m <= p4_m; p5_w <= p4_w; p5_k <= p4_k;
            if (op == 4'd0) begin
                p5_x0 <= {1'b1, c_fg}; p5_x1 <= {1'b1, c_fg}; p5_x2 <= {1'b1, c_fg}; p5_x3 <= {1'b1, c_fg};
            end else begin
                p5_x0 <= xform(lane_q[p4_l0], lane_q[p4_l0][3'd7 - p4_b0], op == 4'd2);
                p5_x1 <= xform(lane_q[p4_l1], lane_q[p4_l1][3'd7 - p4_b1], op == 4'd2);
                p5_x2 <= xform(lane_q[p4_l2], lane_q[p4_l2][3'd7 - p4_b2], op == 4'd2);
                p5_x3 <= xform(lane_q[p4_l3], lane_q[p4_l3][3'd7 - p4_b3], op == 4'd2);
            end
            // etapa 6: empaquetado
            if (p5_v) begin : pack
                reg [8:0] x0, x1, x2, x3;
                reg [31:0] d;
                reg [3:0]  m;
                x0 = p5_x0; x1 = p5_x1; x2 = p5_x2; x3 = p5_x3;
                if (p5_last && p5_k == 2'd3 && (fast || op == 4'd0)) begin
                    // ranura rápida: palabra completa
                    d = {x3[7:0], x2[7:0], x1[7:0], x0[7:0]};
                    m = p5_m & {x3[8], x2[8], x1[8], x0[8]};
                    ob_we <= 1'b1; ob_wa <= p5_w; ob_wd <= {m, d};
                end else begin
                    // ranura lenta: un byte en la posición p5_k
                    d = acc_d;
                    m = acc_m;
                    case (p5_k)
                    2'd0: begin d[7:0]   = x0[7:0]; m[0] = p5_m[0] & x0[8]; end
                    2'd1: begin d[15:8]  = x1[7:0]; m[1] = p5_m[1] & x1[8]; end
                    2'd2: begin d[23:16] = x2[7:0]; m[2] = p5_m[2] & x2[8]; end
                    default: begin d[31:24] = x3[7:0]; m[3] = p5_m[3] & x3[8]; end
                    endcase
                    if (p5_k == 2'd0) m = {3'b000, p5_m[0] & x0[8]};
                    acc_d <= d; acc_m <= m;
                    if (p5_last) begin
                        ob_we <= 1'b1; ob_wa <= p5_w; ob_wd <= {m, d};
                    end
                end
            end
        end
    end
endmodule
`default_nettype wire
