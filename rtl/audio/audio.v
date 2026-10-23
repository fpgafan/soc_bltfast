// ============================================================================
// audio.v - Motor de sonido: 32 voces wavetable/PCM con DMA desde la SDRAM
//
//  Cada voz reproduce una muestra (8 o 16 bits, mono o estéreo) desde la
//  SDRAM con paso de tono 16.16 (1.0 = 48 kHz), interpolación lineal,
//  envolvente ADSR por hardware, volumen L/R y bucle. Sirve igual para notas
//  MIDI (instrumentos sampleados) que para PCM en streaming (bucle sobre un
//  buffer circular + evento al dar la vuelta / al terminar).
//  Las muestras se leen por ráfagas de 32 bytes a una caché de 2 líneas por voz.
//  Salida: 48 kHz estéreo 16 bits (tick48 viene del reloj de píxel). La
//  entrada 'ext' (OPL2, mono) se suma a los dos canales antes del volumen general.
//
//  Registros (base 0x8000_5000):
//   Voz v (solo escritura), +v*0x20:
//     +0x00 CTRL   [1:0] formato: 0 = 8 bits mono, 1 = 16 bits mono,
//                        2 = 16 bits estéreo (L,R), 3 = 8 bits estéreo
//                  [2] bucle, [3] interpolación lineal, [4] evento al acabar/bucle
//     +0x04 START  dirección en bytes de la muestra 0 (SDRAM)
//     +0x08 LEN    número de muestras (tramas)
//     +0x0C LOOP   muestra de inicio del bucle
//     +0x10 PITCH  incremento por muestra de salida, 16.16
//     +0x14 VOL    [7:0] izquierdo, [15:8] derecho
//     +0x18 ADSR   [7:0] ataque, [15:8] caída, [23:16] nivel de sostenido,
//                  [31:24] relajación. Velocidad r -> incremento por muestra
//                  (16 + r[3:0]) << r[7:4] sobre una escala de 2^24
//                  (r = 0: ~21 s ; r = 0xFF: inmediato)
//   (el estado de las voces no se lee directamente: ver MON_*)
//   Globales:
//     0x800 CTRL    [7:0] volumen general (0x80 = 1.0), [8] motor activo
//     0x804 KEYON   W: máscara -> la voz arranca desde 0 con ataque
//     0x808 KEYOFF  W: máscara -> fase de relajación
//     0x80C ACTIVE  R: máscara de voces sonando
//     0x810 EVENT   R: voces que han dado la vuelta o terminado; W: 1 borra
//     0x814 IRQ_EN  RW máscara de eventos que generan interrupción
//     0x818 COUNT   R: muestras de salida generadas
//     0x81C STOP    W: máscara -> parada inmediata
//     0x820 LAST    R: última muestra {R, L}
//     0x824 MON_V   RW voz que se monitoriza
//     0x828 MON_POS R: posición (muestras) de esa voz
//     0x82C MON_ENV R: [25:24] fase (0 A, 1 D, 2 S, 3 R), [23:0] envolvente
// ============================================================================
`default_nettype none
module audio (
    input  wire        clk,
    input  wire        rst,
    input  wire        sel,
    input  wire        we,
    input  wire [11:0] a,
    input  wire [31:0] wd,
    output reg  [31:0] rd,
    output wire        irq,
    input  wire        tick48,
    input  wire signed [15:0] ext,       // otra fuente (OPL2) que se suma a la mezcla
    // maestro SDRAM (lectura)
    output reg         m_req,
    output reg  [22:2] m_addr,
    output wire [3:0]  m_len,
    input  wire        m_ack,
    input  wire [31:0] m_rdata,
    input  wire        m_rvalid,
    // salida
    output reg         out_valid,
    output reg  [15:0] out_l,
    output reg  [15:0] out_r
);
    assign m_len = 4'd7;

    // =====================================================================
    // Registros globales
    // =====================================================================
    reg [7:0]  mvol;
    reg        en;
    reg [31:0] active, ev, irq_en;
    reg [31:0] kon_p, koff_p, stop_p;   // peticiones pendientes por voz
    reg [31:0] count;
    assign irq = |(ev & irq_en);

    // =====================================================================
    // RAM de parámetros: 32 voces x 8 palabras (CPU escribe, motor lee)
    // =====================================================================
    reg [31:0] pram [0:255];
    reg [7:0]  pr_a;
    reg [31:0] pr_q;
    always @(posedge clk) begin
        if (sel && we && a[11:10] == 2'b00) pram[a[9:2]] <= wd;
        pr_q <= pram[pr_a];
    end

    // =====================================================================
    // RAM de estado: 32 voces x 4 palabras (motor lee/escribe, CPU lee)
    // =====================================================================
    reg [31:0] sram  [0:127];
    reg [6:0]  sr_a;                     // dirección de lectura
    reg [6:0]  sr_wa;                    // dirección de escritura
    reg        sr_we;
    reg [31:0] sr_wd, sr_q;
    always @(posedge clk) if (sr_we) sram[sr_wa] <= sr_wd;
    always @(posedge clk) sr_q <= sram[sr_a];
    // monitor: posición/envolvente de una voz elegida (la CPU no lee la RAM)
    reg [4:0]  mon_v;
    reg [31:0] mon_pos, mon_env;

    // =====================================================================
    // Caché de muestras: 32 voces x 2 líneas x 8 palabras
    // =====================================================================
    reg [31:0] cram [0:511];
    reg        cr_we;
    reg [8:0]  cr_wa, cr_ra;
    reg [31:0] cr_wd, cr_q;
    always @(posedge clk) begin
        if (cr_we) cram[cr_wa] <= cr_wd;
        cr_q <= cram[cr_ra];
    end
    // etiquetas: una RAM distribuida por línea (lectura asíncrona por voz)
    reg [18:0] ctag0 [0:31] /* synthesis syn_ramstyle = "distributed_ram" */;
    reg [18:0] ctag1 [0:31] /* synthesis syn_ramstyle = "distributed_ram" */;
    integer ti;
    initial for (ti = 0; ti < 32; ti = ti + 1) begin ctag0[ti] = 19'd0; ctag1[ti] = 19'd0; end
    reg        tg_we;
    reg        tg_slot;
    reg [18:0] tg_d;

    // =====================================================================
    // Bus de registros
    // =====================================================================
    reg [31:0] last;
    wire       glb = (a[11] == 1'b1);
    // las máscaras escritas por la CPU se registran un ciclo
    reg  [31:0] kon_set, koff_set, stop_set, ev_clr;
    always @(posedge clk) begin
        kon_set  <= (sel && we && glb && a[7:2] == 6'h01) ? wd : 32'd0;
        koff_set <= (sel && we && glb && a[7:2] == 6'h02) ? wd : 32'd0;
        stop_set <= (sel && we && glb && a[7:2] == 6'h07) ? wd : 32'd0;
        ev_clr   <= (sel && we && glb && a[7:2] == 6'h04) ? wd : 32'd0;
    end
    always @(posedge clk) begin
        if (glb) begin
            case (a[7:2])
            6'h00: rd <= {23'd0, en, mvol};
            6'h03: rd <= active;
            6'h04: rd <= ev;
            6'h05: rd <= irq_en;
            6'h06: rd <= count;
            6'h08: rd <= last;
            6'h09: rd <= {27'd0, mon_v};
            6'h0A: rd <= mon_pos;
            6'h0B: rd <= mon_env;
            default: rd <= 32'd0;
            endcase
        end else
            rd <= 32'd0;
    end

    // =====================================================================
    // Motor
    // =====================================================================
    localparam S_IDLE = 5'd0, S_VST = 5'd1, S_RD = 5'd2, S_ADDR = 5'd3, S_TAG = 5'd4,
               S_FETCH = 5'd5, S_CW0 = 5'd6, S_CW1 = 5'd7, S_CW2 = 5'd8, S_M1 = 5'd9,
               S_M2 = 5'd10, S_M3 = 5'd11, S_UPD = 5'd12, S_WB = 5'd13, S_MIX = 5'd14,
               S_OUT = 5'd15, S_M4 = 5'd16, S_POS = 5'd17, S_HIT = 5'd18;
    reg [4:0]  st;
    reg [4:0]  v;
    reg [3:0]  ri;                       // índice de lectura de parámetros
    // parámetros de la voz
    reg [4:0]  p_ctrl;
    reg [22:0] p_start;
    reg [23:0] p_len, p_loop;
    reg [31:0] p_pitch;
    reg [7:0]  p_vl, p_vr;
    reg [7:0]  p_ar, p_dr, p_sl, p_rr;
    // estado
    reg [23:0] s_pos;
    reg [15:0] s_frac;
    reg [1:0]  s_ph;                     // 0 ataque, 1 caída, 2 sostenido, 3 relajación
    reg [23:0] s_env;
    reg        v_on;                     // la voz suena tras aplicar peticiones
    // direcciones
    reg [23:0] f1;                       // índice de la segunda muestra
    reg [22:0] ad0, ad1;
    reg        sl0, sl1;                 // línea de caché usada por cada muestra
    reg        miss_n;                   // qué muestra falla (0/1)
    reg [3:0]  fcnt;
    reg        fslot;
    reg [31:0] w0;
    reg [23:0] p_span;                   // LEN - LOOP
    reg [23:0] s_pm;                     // posición - span
    reg [39:0] pn, pw;
    // muestras
    reg signed [15:0] l0, r0, l1, r1;
    reg signed [16:0] dl, dr;
    reg signed [33:0] pl, pr;
    reg [23:0] gl, gr;
    reg signed [15:0] il, ir;
    reg signed [31:0] cl, cr;
    reg signed [23:0] acc_l, acc_r;

    wire [1:0] fmt = p_ctrl[1:0];
    // bytes por trama: 8 mono 1, 16 mono 2, 16 estéreo 4, 8 estéreo 2
    function [22:0] fofs(input [23:0] f, input [1:0] fm);
        case (fm)
        2'd0:    fofs = f[22:0];
        2'd1,
        2'd3:    fofs = {f[21:0], 1'b0};
        default: fofs = {f[20:0], 2'b00};
        endcase
    endfunction
    // extrae {R, L} de la palabra según el formato y la dirección
    function [31:0] samp(input [31:0] w, input [1:0] ba, input [1:0] fm);
        reg [15:0] h;
        reg [7:0]  b;
        begin
            h = ba[1] ? w[31:16] : w[15:0];
            b = ba[1] ? (ba[0] ? w[31:24] : w[23:16]) : (ba[0] ? w[15:8] : w[7:0]);
            case (fm)
            2'd0:    samp = {b, 8'd0, b, 8'd0};
            2'd1:    samp = {h, h};
            2'd2:    samp = w;
            default: samp = {h[15:8], 8'd0, h[7:0], 8'd0};
            endcase
        end
    endfunction
    function [23:0] rate(input [7:0] r);
        rate = {19'd1, r[3:0]} << r[7:4];
    endfunction

    always @(posedge clk) if (tg_we) begin
        if (tg_slot) ctag1[v] <= tg_d; else ctag0[v] <= tg_d;
    end
    wire [18:0] tag0 = ctag0[v];
    wire [18:0] tag1 = ctag1[v];
    wire [17:0] ln0  = ad0[22:5];
    wire [17:0] ln1  = ad1[22:5];
    // aciertos registrados (se calculan en S_HIT y se usan en S_CW0)
    reg h00, h01, h10, h11;

    reg  [23:0] r_a, r_d, r_r;          // velocidades decodificadas
    reg  [24:0] env_up, env_dn_d, env_dn_r;   // calculadas en S_M4
    wire [23:0] sus = {p_sl, 16'd0};
    wire [39:0] pos_n = {s_pos, s_frac} + {8'd0, p_pitch};

    reg signed [31:0] mix_l, mix_r;

    always @(posedge clk) begin
        sr_we     <= 1'b0;
        cr_we     <= 1'b0;
        tg_we     <= 1'b0;
        out_valid <= 1'b0;
        if (m_ack) m_req <= 1'b0;
        if (rst) begin
            st <= S_IDLE;
            mvol <= 8'h80; en <= 1'b1; mon_v <= 5'd0;
            active <= 32'd0; ev <= 32'd0; irq_en <= 32'd0;
            kon_p <= 32'd0; koff_p <= 32'd0; stop_p <= 32'd0;
            count <= 32'd0;
            m_req <= 1'b0;
            last <= 32'd0;
        end else begin
            // peticiones de la CPU (se acumulan; el motor las aplica)
            kon_p  <= kon_p  | kon_set;
            koff_p <= koff_p | koff_set;
            stop_p <= stop_p | stop_set;
            ev     <= ev & ~ev_clr;
            if (sel && we && glb && a[7:2] == 6'h00) begin mvol <= wd[7:0]; en <= wd[8]; end
            if (sel && we && glb && a[7:2] == 6'h05) irq_en <= wd;
            if (sel && we && glb && a[7:2] == 6'h09) mon_v <= wd[4:0];

            case (st)
            S_IDLE: if (tick48) begin
                v <= 5'd0;
                acc_l <= {{8{ext[15]}}, ext}; acc_r <= {{8{ext[15]}}, ext};
                st <= en ? S_VST : S_MIX;
            end
            // ------------------------------------------------------------ voz
            S_VST: begin
                if (!(active[v] | kon_p[v])) begin
                    stop_p[v] <= stop_set[v];
                    koff_p[v] <= koff_set[v];
                    if (v == 5'd31) st <= S_MIX; else v <= v + 5'd1;
                end else begin
                    pr_a <= {v, 3'd0};
                    sr_a <= {v, 2'd0};
                    ri   <= 4'd0;
                    st   <= S_RD;
                end
            end
            S_RD: begin
                // pr_q/sr_q = palabra ri-1
                ri   <= ri + 4'd1;
                pr_a <= {v, ri[2:0] + 3'd1};
                if (ri < 4'd3) sr_a <= {v, ri[1:0] + 2'd1};
                case (ri)
                4'd1: begin p_ctrl <= pr_q[4:0]; s_pos <= sr_q[23:0]; end
                4'd2: begin p_start <= pr_q[22:0]; s_frac <= sr_q[15:0]; s_ph <= sr_q[17:16]; end
                4'd3: begin p_len <= pr_q[23:0]; s_env <= sr_q[23:0]; end
                4'd4: p_loop <= pr_q[23:0];
                4'd5: p_pitch <= pr_q;
                4'd6: begin p_vl <= pr_q[7:0]; p_vr <= pr_q[15:8]; end
                4'd7: begin p_ar <= pr_q[7:0]; p_dr <= pr_q[15:8]; p_sl <= pr_q[23:16]; p_rr <= pr_q[31:24]; end
                default: ;
                endcase
                if (ri == 4'd8) begin
                    r_a <= rate(p_ar); r_d <= rate(p_dr); r_r <= rate(p_rr);
                    // aplicar peticiones
                    v_on <= 1'b1;
                    if (kon_p[v]) begin
                        s_pos <= 24'd0; s_frac <= 16'd0; s_env <= 24'd0; s_ph <= 2'd0;
                        kon_p[v]  <= kon_set[v];
                        koff_p[v] <= koff_set[v];
                        stop_p[v] <= stop_set[v];
                    end else if (stop_p[v]) begin
                        v_on <= 1'b0;
                        stop_p[v] <= stop_set[v];
                        koff_p[v] <= koff_set[v];
                    end else if (koff_p[v]) begin
                        s_ph <= 2'd3;
                        koff_p[v] <= koff_set[v];
                    end
                    st <= S_ADDR;
                end
            end
            S_ADDR: begin
                if (!v_on) begin
                    active[v] <= 1'b0;
                    st <= S_WB;
                end else begin
                    // segunda muestra para la interpolación (bucle o la misma al final)
                    if (s_pos + 24'd1 >= p_len)
                        f1 <= p_ctrl[2] ? p_loop : s_pos;
                    else
                        f1 <= s_pos + 24'd1;
                    ad0 <= p_start + fofs(s_pos, fmt);
                    p_span <= p_len - p_loop;
                    st  <= S_TAG;
                end
            end
            S_TAG: begin
                ad1 <= p_start + fofs(f1, fmt);
                s_pm <= s_pos - p_span;
                st  <= S_HIT;
            end
            S_HIT: begin
                h00 <= tag0[18] && tag0[17:0] == ln0;
                h01 <= tag1[18] && tag1[17:0] == ln0;
                h10 <= tag0[18] && tag0[17:0] == ln1;
                h11 <= tag1[18] && tag1[17:0] == ln1;
                st  <= S_CW0;
            end
            S_CW0: begin
                // comprobar etiquetas de las dos muestras
                if (!(h00 | h01)) begin
                    miss_n <= 1'b0;
                    fslot  <= h11 & ~h10 ? 1'b0 : (h10 ? 1'b1 : 1'b0);
                    st     <= S_FETCH;
                    m_req  <= 1'b1;
                    m_addr <= {ln0, 3'd0};
                    fcnt   <= 4'd0;
                end else if (!(h10 | h11)) begin
                    miss_n <= 1'b1;
                    fslot  <= h00 ? 1'b1 : 1'b0;
                    st     <= S_FETCH;
                    m_req  <= 1'b1;
                    m_addr <= {ln1, 3'd0};
                    fcnt   <= 4'd0;
                end else begin
                    sl0   <= h00 ? 1'b0 : 1'b1;
                    sl1   <= h10 ? 1'b0 : 1'b1;
                    cr_ra <= {v, h00 ? 1'b0 : 1'b1, ad0[4:2]};
                    st    <= S_CW1;
                end
            end
            S_FETCH: begin
                if (m_rvalid) begin
                    cr_we <= 1'b1;
                    cr_wa <= {v, fslot, fcnt[2:0]};
                    cr_wd <= m_rdata;
                    fcnt  <= fcnt + 4'd1;
                    if (fcnt == 4'd7) begin
                        tg_we   <= 1'b1;
                        tg_slot <= fslot;
                        tg_d    <= {1'b1, miss_n ? ln1 : ln0};
                        st <= S_TAG;              // volver a comprobar (tras escribir la etiqueta)
                    end

                end
            end
            S_CW1: begin
                cr_ra <= {v, sl1, ad1[4:2]};
                st    <= S_CW2;
            end
            S_CW2: begin
                w0 <= cr_q;                      // palabra de la muestra 0
                st <= S_M1;
            end
            // ------------------------------------------------------------ cálculo
            S_M1: begin : m1
                reg [31:0] sa, sb;
                sa = samp(w0, ad0[1:0], fmt);
                sb = samp(cr_q, ad1[1:0], fmt);
                l0 <= sa[15:0];  r0 <= sa[31:16];
                l1 <= sb[15:0];  r1 <= sb[31:16];
                dl <= p_ctrl[3] ? $signed({sb[15], sb[15:0]}) - $signed({sa[15], sa[15:0]}) : 17'sd0;
                dr <= p_ctrl[3] ? $signed({sb[31], sb[31:16]}) - $signed({sa[31], sa[31:16]}) : 17'sd0;
                st <= S_M2;
            end
            S_M2: begin
                pl <= dl * $signed({1'b0, s_frac});
                pr <= dr * $signed({1'b0, s_frac});
                gl <= s_env[23:8] * p_vl;
                gr <= s_env[23:8] * p_vr;
                st <= S_M3;
            end
            S_M3: begin
                il <= l0 + pl[31:16];
                ir <= r0 + pr[31:16];
                st <= S_M4;
            end
            S_M4: begin
                cl <= il * $signed({1'b0, gl[23:8]});
                cr <= ir * $signed({1'b0, gr[23:8]});
                pn <= pos_n;
                pw <= {s_pm, s_frac} + {8'd0, p_pitch};
                env_up   <= {1'b0, s_env} + {1'b0, r_a};
                env_dn_d <= {1'b0, s_env} - {1'b0, r_d};
                env_dn_r <= {1'b0, s_env} - {1'b0, r_r};
                st <= S_UPD;
            end
            S_UPD: begin
                // contribución a la mezcla
                acc_l <= acc_l + $signed(cl[31:16]);
                acc_r <= acc_r + $signed(cr[31:16]);
                // posición
                if (pn[39:16] >= p_len) begin
                    if (p_ctrl[2]) begin
                        s_pos  <= (pw[39:16] >= p_len) ? p_loop : pw[39:16];
                        s_frac <= pn[15:0];
                    end else begin
                        v_on <= 1'b0;
                    end
                    if (p_ctrl[4]) ev[v] <= 1'b1;
                end else begin
                    s_pos  <= pn[39:16];
                    s_frac <= pn[15:0];
                end
                // envolvente
                case (s_ph)
                2'd0: if (env_up[24] || env_up[23:0] == 24'hFFFFFF) begin
                          s_env <= 24'hFFFFFF; s_ph <= 2'd1;
                      end else s_env <= env_up[23:0];
                2'd1: if (env_dn_d[24] || env_dn_d[23:0] <= sus) begin
                          s_env <= sus; s_ph <= 2'd2;
                      end else s_env <= env_dn_d[23:0];
                2'd2: s_env <= sus;
                default: if (env_dn_r[24] || env_dn_r[23:0] == 24'd0) begin
                          s_env <= 24'd0; v_on <= 1'b0;
                      end else s_env <= env_dn_r[23:0];
                endcase
                st <= S_WB;
                ri <= 4'd0;
            end
            // ------------------------------------------------------------ escritura del estado
            S_WB: begin
                ri    <= ri + 4'd1;
                sr_we <= 1'b1;
                sr_wa <= {v, ri[1:0]};
                case (ri[1:0])
                2'd0: sr_wd <= {8'd0, s_pos};
                2'd1: sr_wd <= {14'd0, s_ph, s_frac};
                default: sr_wd <= {8'd0, s_env};
                endcase
                if (ri == 4'd2) begin
                    active[v] <= v_on;
                    if (v == mon_v) begin
                        mon_pos <= {8'd0, s_pos};
                        mon_env <= {6'd0, s_ph, s_env};
                    end
                    if (v == 5'd31) st <= S_MIX;
                    else begin
                        v  <= v + 5'd1;
                        st <= S_VST;
                    end
                end
            end
            // ------------------------------------------------------------ mezcla final
            S_MIX: begin
                mix_l <= acc_l * $signed({1'b0, mvol});
                mix_r <= acc_r * $signed({1'b0, mvol});
                st <= S_OUT;
            end
            S_OUT: begin : sat
                reg signed [31:0] xl, xr;
                xl = mix_l >>> 7;
                xr = mix_r >>> 7;
                out_l <= (xl > 32'sd32767) ? 16'h7FFF : (xl < -32'sd32768) ? 16'h8000 : xl[15:0];
                out_r <= (xr > 32'sd32767) ? 16'h7FFF : (xr < -32'sd32768) ? 16'h8000 : xr[15:0];
                out_valid <= 1'b1;
                count <= count + 32'd1;
                st <= S_IDLE;
            end
            default: st <= S_IDLE;
            endcase
            if (out_valid) last <= {out_r, out_l};
        end
    end
endmodule
`default_nettype wire
