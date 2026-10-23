// ============================================================================
// cpu_mem.v - Unidad de memoria de la CPU
//
//  * ROM de arranque (BSRAM, $readmemh) en 0x0000_0000 (cacheable)
//  * Puerto de la SDRAM (maestro del controlador): rellenos de icache / dcache
//    (ráfagas de 8 palabras), lecturas no cacheables (0x5xxx_xxxx = alias sin
//    caché de la SDRAM) y escrituras desde los buffers de combinación.
//  * Bus de E/S (0x8xxx_xxxx): una transacción cada vez (req -> ack).
//
//  Escrituras: dos buffers de combinación (WCB) de una línea de 32 bytes con
//  máscara por byte. Los stores a la misma línea se fusionan; al cambiar de
//  línea la anterior se vacía con una ráfaga (palabras sin bytes válidos
//  recortadas por los extremos). Un store de E/S espera a que los WCB estén
//  vacíos y bloquea los siguientes stores hasta ejecutarse (orden estricto).
//  Un WCB activo sin actividad durante 32 ciclos se vacía solo.
//
//  Los rellenos de dcache y las lecturas no cacheables esperan a que los WCB
//  y el store de E/S pendiente se hayan escrito (orden lectura tras escritura).
// ============================================================================
`default_nettype none
module cpu_mem #(
    parameter ROM_AW   = 11,            // palabras de ROM: 2^11 = 8 KB
    parameter ROM_FILE = "boot.hex"
)(
    input  wire        clk,
    input  wire        rst,
    // ---------------- núcleo
    input  wire        ic_fill_req,
    input  wire [31:0] ic_fill_addr,
    output reg         ic_fill_done,
    input  wire        ic_inval_req,
    output reg         ic_inval_done,
    input  wire        mreq,
    input  wire [31:0] mreq_addr,
    input  wire        mreq_fence,
    output wire        mem_hold,
    output reg         io_valid,
    output reg  [31:0] io_addr,
    output reg  [31:0] io_rdata,
    input  wire        io_take,
    input  wire        sb_push,
    input  wire [31:0] sb_addr,
    input  wire [31:0] sb_data,
    input  wire [3:0]  sb_strb,
    output reg         sb_full,
    // ---------------- escrituras a las cachés
    output reg         icw_de,          // dato de icache
    output reg  [10:0] icw_didx,
    output reg  [31:0] icw_ddata,
    output reg         icw_te,
    output reg  [7:0]  icw_tidx,
    output reg  [11:0] icw_tdata,
    output reg         dcw_de,
    output reg  [10:0] dcw_didx,
    output reg  [31:0] dcw_ddata,
    output reg         dcw_te,
    output reg  [7:0]  dcw_tidx,
    output reg  [11:0] dcw_tdata,
    // ---------------- maestro de la SDRAM
    output reg         m_req,
    output reg         m_we,
    output reg  [22:2] m_addr,
    output reg  [3:0]  m_len,           // palabras - 1
    input  wire        m_ack,
    output wire [31:0] m_wdata,
    output wire [3:0]  m_wmask,
    input  wire        m_wnext,
    input  wire [31:0] m_rdata,
    input  wire        m_rvalid,
    // ---------------- bus de E/S
    output reg         io_req,
    output reg         io_we,
    output reg  [31:0] io_a,
    output reg  [31:0] io_wd,
    output reg  [3:0]  io_ws,
    input  wire        io_ack,
    input  wire [31:0] io_rd
);
    // ========================================================================
    // ROM
    // ========================================================================
    reg  [31:0] rom [0:(1<<ROM_AW)-1];
    integer ri;
    initial begin
`ifdef SIM
        for (ri = 0; ri < (1<<ROM_AW); ri = ri + 1) rom[ri] = 32'h0000_0013;   // nop
`endif
        $readmemh(ROM_FILE, rom);
    end
    reg  [ROM_AW-1:0] rom_a;
    reg  [31:0] rom_q;
    always @(posedge clk) rom_q <= rom[rom_a];

    // ========================================================================
    // Buffers de combinación de escritura (2)
    // ========================================================================
    reg         wv   [0:1];             // ocupado
    reg         wfl  [0:1];             // pendiente de vaciar
    reg  [22:5] wtag [0:1];
    // datos de los WCB: RAM distribuida por carril de byte (16 = 2 x 8 palabras),
    // escritura con máscara de bytes (sin multiplexores de fusión)
    reg  [7:0]  wl0 [0:15] /* synthesis syn_ramstyle = "distributed_ram" */;
    reg  [7:0]  wl1 [0:15] /* synthesis syn_ramstyle = "distributed_ram" */;
    reg  [7:0]  wl2 [0:15] /* synthesis syn_ramstyle = "distributed_ram" */;
    reg  [7:0]  wl3 [0:15] /* synthesis syn_ramstyle = "distributed_ram" */;
    reg  [3:0]  wm0 [0:7], wm1 [0:7];
    reg         wact;                   // índice del WCB activo (recibe stores)
    reg  [4:0]  wtimer;

    reg         iop;                    // store de E/S pendiente
    reg  [31:0] iop_a, iop_d;
    reg  [3:0]  iop_s;

    // FIFO de entrada de 2 stores entre el núcleo y los WCB. El núcleo solo ve
    // sb_full registrado (no depende de comparar etiquetas en el mismo ciclo).
    // La cabeza (q0) se procesa cuando los WCB pueden aceptarla; un store de
    // E/S espera a que no haya otro pendiente y bloquea los posteriores
    // (orden estricto de escrituras).
    reg         q0_v, q1_v;
    reg  [31:0] q0_addr, q0_data, q1_addr, q1_data;
    reg  [3:0]  q0_strb, q1_strb;
    wire [31:0] q_addr = q0_addr;
    wire [31:0] q_data = q0_data;
    wire [3:0]  q_strb = q0_strb;
    wire q_io    = (q_addr[31:28] == 4'h8) | (q_addr[31:28] == 4'h9) | (q_addr[31:28] == 4'h1);
    wire q_sd    = (q_addr[31:28] == 4'h4) | (q_addr[31:28] == 4'h5);
    wire act_v   = wact ? wv[1] : wv[0];
    wire act_fl  = wact ? wfl[1] : wfl[0];
    wire [22:5] act_tag = wact ? wtag[1] : wtag[0];
    wire oth_v   = wact ? wv[0] : wv[1];
    wire act_match = act_v & ~act_fl & (act_tag == q_addr[22:5]);
    // La cabeza se procesa en dos fases: (1) se evalúa y se registra la
    // decisión (qm_*), (2) se aplica. Entre ambas el estado de los WCB solo
    // puede cambiar a favor (un vaciado que termina), porque el marcado por
    // inactividad no se hace con una decisión positiva pendiente.
    wire q_ok_c  = q_io ? ~iop :
                   q_sd ? (~iop & (act_match | ~act_v | ~oth_v)) : 1'b1;
    reg  qm_v, qm_ok, qm_match;
    wire q_pop   = q0_v & qm_v & qm_ok;
    wire q_v     = q_pop;                // procesar la cabeza
    wire [1:0] q_cnt  = {1'b0, q0_v} + {1'b0, q1_v};
    wire [1:0] q_cntn = q_cnt - {1'b0, q_pop} + {1'b0, sb_push};
    wire wcb_empty = ~wv[0] & ~wv[1];  // (la FIFO no cuenta: es más joven que iop)

    // vaciado en curso
    reg         fl_busy;
    reg         fl_buf;
    reg  [2:0]  fl_idx;
    assign m_wdata = {wl3[{fl_buf, fl_idx}], wl2[{fl_buf, fl_idx}], wl1[{fl_buf, fl_idx}], wl0[{fl_buf, fl_idx}]};
    assign m_wmask = fl_buf ? wm1[fl_idx] : wm0[fl_idx];
    // escritura de datos: al WCB activo (fusión o línea nueva en él) o al otro (cambio)
    wire       w_we = q_v & q_sd;
    wire       w_tb = (qm_match | ~act_v) ? wact : ~wact;
    wire [3:0] w_ix = {w_tb, q_addr[4:2]};
    always @(posedge clk) if (w_we) begin
        if (q_strb[0]) wl0[w_ix] <= q_data[7:0];
        if (q_strb[1]) wl1[w_ix] <= q_data[15:8];
        if (q_strb[2]) wl2[w_ix] <= q_data[23:16];
        if (q_strb[3]) wl3[w_ix] <= q_data[31:24];
    end

    function [31:0] merge(input [31:0] o, input [31:0] n, input [3:0] m);
        merge = {m[3] ? n[31:24] : o[31:24], m[2] ? n[23:16] : o[23:16],
                 m[1] ? n[15:8]  : o[15:8],  m[0] ? n[7:0]   : o[7:0]};
    endfunction

    // primera / última palabra con algún byte válido
    function [2:0] first_set(input [7:0] v);
        integer i;
        begin
            first_set = 3'd0;
            for (i = 7; i >= 0; i = i - 1) if (v[i]) first_set = i[2:0];
        end
    endfunction
    function [2:0] last_set(input [7:0] v);
        integer i;
        begin
            last_set = 3'd0;
            for (i = 0; i < 8; i = i + 1) if (v[i]) last_set = i[2:0];
        end
    endfunction
    wire [7:0] wany0 = {|wm0[7], |wm0[6], |wm0[5], |wm0[4], |wm0[3], |wm0[2], |wm0[1], |wm0[0]};
    wire [7:0] wany1 = {|wm1[7], |wm1[6], |wm1[5], |wm1[4], |wm1[3], |wm1[2], |wm1[1], |wm1[0]};

    // ========================================================================
    // Peticiones pendientes
    // ========================================================================
    reg        dreq_p;                  // replay de carga
    reg [31:0] dreq_a;
    reg        fence_p;
    assign mem_hold = dreq_p | fence_p;

    // ========================================================================
    // FSM
    // ========================================================================
    localparam S_IDLE = 4'd0, S_FLUSH = 4'd1, S_IOW = 4'd2, S_IOR = 4'd3,
               S_SDRD = 4'd4, S_ROMRD = 4'd5, S_SDR1 = 4'd6, S_INV = 4'd7,
               S_FLWAIT = 4'd8;
    reg [3:0]  st;
    reg        fill_i;                  // relleno de icache (1) o de dcache (0)
    reg [31:0] fa;                      // dirección de la línea / palabra
    reg [3:0]  fcnt;                    // palabras recibidas
    reg [3:0]  rcnt;                    // direcciones de ROM emitidas
    reg [8:0]  icnt;                    // barrido de invalidación
    reg        inv_i;

    wire wcb_need_flush = (wv[0] & wfl[0]) | (wv[1] & wfl[1]);
    wire need_drain     = ~wcb_empty | iop | q0_v | q1_v;

    integer j;
    always @(posedge clk) begin
        ic_fill_done  <= 1'b0;
        ic_inval_done <= 1'b0;
        icw_de <= 1'b0; icw_te <= 1'b0;
        dcw_de <= 1'b0; dcw_te <= 1'b0;
        io_req <= 1'b0;
        if (rst) begin
            st <= S_IDLE;
            wv[0] <= 1'b0; wv[1] <= 1'b0; wfl[0] <= 1'b0; wfl[1] <= 1'b0;
            wact <= 1'b0; wtimer <= 5'd0;
            iop <= 1'b0;
            dreq_p <= 1'b0; fence_p <= 1'b0;
            io_valid <= 1'b0;
            m_req <= 1'b0;
            fl_busy <= 1'b0;
            q0_v <= 1'b0; q1_v <= 1'b0;
            sb_full <= 1'b0;
            qm_v <= 1'b0;
        end else begin
            // ------------------------------------------------ peticiones del núcleo
            if (mreq)       begin dreq_p <= 1'b1; dreq_a <= mreq_addr; end
            if (mreq_fence) fence_p <= 1'b1;
            if (io_take)    io_valid <= 1'b0;

            // ------------------------------------------------ stores
            // FIFO: avance de la cabeza y entrada del store de M
            if (q_pop) begin
                q0_v <= q1_v;
                q0_addr <= q1_addr; q0_data <= q1_data; q0_strb <= q1_strb;
                q1_v <= 1'b0;
            end
            if (sb_push) begin
                if ((q_pop && !q1_v) || (!q0_v)) begin
                    q0_v <= 1'b1; q0_addr <= sb_addr; q0_data <= sb_data; q0_strb <= sb_strb;
                end else begin
                    q1_v <= 1'b1; q1_addr <= sb_addr; q1_data <= sb_data; q1_strb <= sb_strb;
                end
            end
            // evaluación de la cabeza (fase 1) / aplicación (fase 2)
            if (q0_v && !qm_v) begin
                qm_v     <= 1'b1;
                qm_ok    <= q_ok_c;
                qm_match <= act_match;
            end else
                qm_v <= 1'b0;
            // lleno: las dos entradas ocupadas tras este ciclo
            sb_full <= (q_cntn == 2'd2);
            if (q_v) begin
                if (q_io) begin
                    iop   <= 1'b1;
                    iop_a <= q_addr; iop_d <= q_data; iop_s <= q_strb;
                end else if (q_sd) begin
                    wtimer <= 5'd0;
                    if (qm_match) begin
                        if (wact) wm1[q_addr[4:2]] <= wm1[q_addr[4:2]] | q_strb;
                        else      wm0[q_addr[4:2]] <= wm0[q_addr[4:2]] | q_strb;
                    end else begin
                        // nueva línea: en el activo si está libre, si no en el otro
                        // (sb_full garantiza que uno de los dos lo está)
                        if (!act_v) begin
                            if (wact) begin wv[1] <= 1'b1; wfl[1] <= 1'b0; wtag[1] <= q_addr[22:5]; end
                            else      begin wv[0] <= 1'b1; wfl[0] <= 1'b0; wtag[0] <= q_addr[22:5]; end
                            for (j = 0; j < 8; j = j + 1) begin
                                if (wact) wm1[j] <= (j == q_addr[4:2]) ? q_strb : 4'd0;
                                else      wm0[j] <= (j == q_addr[4:2]) ? q_strb : 4'd0;
                            end
                        end else begin
                            if (wact) begin wfl[1] <= 1'b1; wv[0] <= 1'b1; wfl[0] <= 1'b0; wtag[0] <= q_addr[22:5]; end
                            else      begin wfl[0] <= 1'b1; wv[1] <= 1'b1; wfl[1] <= 1'b0; wtag[1] <= q_addr[22:5]; end
                            for (j = 0; j < 8; j = j + 1) begin
                                if (wact) wm0[j] <= (j == q_addr[4:2]) ? q_strb : 4'd0;
                                else      wm1[j] <= (j == q_addr[4:2]) ? q_strb : 4'd0;
                            end
                            wact <= ~wact;
                        end
                    end
                end
                // stores a la ROM u otras zonas: se descartan
            end else if (act_v & ~act_fl & (~q0_v | (qm_v & ~qm_ok))) begin
                // vaciado por inactividad o porque alguien necesita la memoria
                // (solo sin store pendiente o con la cabeza bloqueada)
                if (wtimer == 5'd31 || dreq_p || fence_p || ic_inval_req || iop) begin
                    if (wact) wfl[1] <= 1'b1; else wfl[0] <= 1'b1;
                end else if (!sb_push && !q0_v)
                    wtimer <= wtimer + 5'd1;
            end

            // ------------------------------------------------ máquina de estados
            case (st)
            S_IDLE: begin
                if (ic_fill_req && !ic_fill_done) begin
                    fill_i <= 1'b1;
                    fa     <= {ic_fill_addr[31:5], 5'd0};
                    fcnt   <= 4'd0;
                    if (ic_fill_addr[31:28] == 4'h0) begin
                        rcnt <= 4'd0;
                        st   <= S_ROMRD;
                    end else begin
                        m_req  <= 1'b1;
                        m_we   <= 1'b0;
                        m_addr <= {ic_fill_addr[22:5], 3'd0};
                        m_len  <= 4'd7;
                        st     <= S_SDRD;
                    end
                end else if (wcb_need_flush) begin
                    // vaciar un WCB marcado (el no activo primero)
                    fl_buf <= (wv[~wact] & wfl[~wact]) ? ~wact : wact;
                    st     <= S_FLUSH;
                end else if (iop && wcb_empty) begin
                    io_req <= 1'b1;
                    io_we  <= 1'b1;
                    io_a   <= iop_a; io_wd <= iop_d; io_ws <= iop_s;
                    st     <= S_IOW;
                end else if (dreq_p && !need_drain) begin
                    if (dreq_a[31:28] == 4'h0) begin
                        fill_i <= 1'b0;
                        fa     <= {dreq_a[31:5], 5'd0};
                        fcnt   <= 4'd0;
                        rcnt   <= 4'd0;
                        st     <= S_ROMRD;
                    end else if (dreq_a[31:28] == 4'h4) begin
                        fill_i <= 1'b0;
                        fa     <= {dreq_a[31:5], 5'd0};
                        fcnt   <= 4'd0;
                        m_req  <= 1'b1;
                        m_we   <= 1'b0;
                        m_addr <= {dreq_a[22:5], 3'd0};
                        m_len  <= 4'd7;
                        st     <= S_SDRD;
                    end else if (dreq_a[31:28] == 4'h5) begin
                        fa     <= dreq_a;
                        m_req  <= 1'b1;
                        m_we   <= 1'b0;
                        m_addr <= dreq_a[22:2];
                        m_len  <= 4'd0;
                        st     <= S_SDR1;
                    end else begin
                        io_req <= 1'b1;
                        io_we  <= 1'b0;
                        io_a   <= dreq_a;
                        st     <= S_IOR;
                    end
                end else if (fence_p && !need_drain) begin
                    inv_i <= 1'b0;
                    icnt  <= 9'd0;
                    st    <= S_INV;
                end else if (ic_inval_req && !need_drain && !ic_inval_done) begin
                    inv_i <= 1'b1;
                    icnt  <= 9'd0;
                    st    <= S_INV;
                end
            end

            // ---------------- relleno desde la SDRAM (8 palabras)
            S_SDRD: begin
                if (m_ack) m_req <= 1'b0;
                if (m_rvalid) begin
                    if (fill_i) begin
                        icw_de <= 1'b1; icw_didx <= {fa[12:5], fcnt[2:0]}; icw_ddata <= m_rdata;
                    end else begin
                        dcw_de <= 1'b1; dcw_didx <= {fa[12:5], fcnt[2:0]}; dcw_ddata <= m_rdata;
                    end
                    fcnt <= fcnt + 4'd1;
                    if (fcnt == 4'd7) begin
                        if (fill_i) begin
                            icw_te <= 1'b1; icw_tidx <= fa[12:5]; icw_tdata <= {1'b1, fa[30], fa[22:13]};
                            ic_fill_done <= 1'b1;
                        end else begin
                            dcw_te <= 1'b1; dcw_tidx <= fa[12:5]; dcw_tdata <= {1'b1, fa[30], fa[22:13]};
                            dreq_p <= 1'b0;
                        end
                        st <= S_IDLE;
                    end
                end
            end

            // ---------------- relleno desde la ROM (lectura síncrona)
            S_ROMRD: begin
                if (rcnt != 4'd8) rcnt <= rcnt + 4'd1;
                if (rcnt != 4'd0) begin
                    if (fill_i) begin
                        icw_de <= 1'b1; icw_didx <= {fa[12:5], fcnt[2:0]}; icw_ddata <= rom_q;
                    end else begin
                        dcw_de <= 1'b1; dcw_didx <= {fa[12:5], fcnt[2:0]}; dcw_ddata <= rom_q;
                    end
                    fcnt <= fcnt + 4'd1;
                    if (fcnt == 4'd7) begin
                        if (fill_i) begin
                            icw_te <= 1'b1; icw_tidx <= fa[12:5]; icw_tdata <= {1'b1, fa[30], fa[22:13]};
                            ic_fill_done <= 1'b1;
                        end else begin
                            dcw_te <= 1'b1; dcw_tidx <= fa[12:5]; dcw_tdata <= {1'b1, fa[30], fa[22:13]};
                            dreq_p <= 1'b0;
                        end
                        st <= S_IDLE;
                    end
                end
            end

            // ---------------- lectura suelta no cacheable de la SDRAM
            S_SDR1: begin
                if (m_ack) m_req <= 1'b0;
                if (m_rvalid) begin
                    io_valid <= 1'b1;
                    io_addr  <= fa;
                    io_rdata <= m_rdata;
                    dreq_p   <= 1'b0;
                    st       <= S_IDLE;
                end
            end

            // ---------------- bus de E/S
            S_IOR: if (io_ack) begin
                io_valid <= 1'b1;
                io_addr  <= io_a;
                io_rdata <= io_rd;
                dreq_p   <= 1'b0;
                st       <= S_IDLE;
            end
            S_IOW: if (io_ack) begin
                iop <= 1'b0;
                st  <= S_IDLE;
            end

            // ---------------- vaciado de un WCB
            S_FLUSH: begin
                // recortar palabras vacías de los extremos
                fl_idx  <= first_set(fl_buf ? wany1 : wany0);
                m_req   <= 1'b1;
                m_we    <= 1'b1;
                m_addr  <= {(fl_buf ? wtag[1] : wtag[0]), first_set(fl_buf ? wany1 : wany0)};
                m_len   <= {1'b0, last_set(fl_buf ? wany1 : wany0) - first_set(fl_buf ? wany1 : wany0)};
                fcnt    <= {1'b0, last_set(fl_buf ? wany1 : wany0) - first_set(fl_buf ? wany1 : wany0)};
                st      <= S_FLWAIT;
            end
            S_FLWAIT: begin
                if (m_ack) m_req <= 1'b0;
                if (m_wnext) begin
                    fl_idx <= fl_idx + 3'd1;
                    fcnt   <= fcnt - 4'd1;
                    if (fcnt == 4'd0) begin
                        if (fl_buf) begin wv[1] <= 1'b0; wfl[1] <= 1'b0; end
                        else        begin wv[0] <= 1'b0; wfl[0] <= 1'b0; end
                        st <= S_IDLE;
                    end
                end
            end

            // ---------------- invalidación de etiquetas
            S_INV: begin
                if (inv_i) begin
                    icw_te <= 1'b1; icw_tidx <= icnt[7:0]; icw_tdata <= 12'd0;
                end else begin
                    dcw_te <= 1'b1; dcw_tidx <= icnt[7:0]; dcw_tdata <= 12'd0;
                end
                icnt <= icnt + 9'd1;
                if (icnt == 9'd255) begin
                    if (inv_i) ic_inval_done <= 1'b1;
                    else       fence_p <= 1'b0;
                    st <= S_IDLE;
                end
            end
            default: st <= S_IDLE;
            endcase

        end
    end

    // dirección de la ROM
    always @(*) begin
        rom_a = fa[ROM_AW+1:2] + {{(ROM_AW-4){1'b0}}, rcnt};
    end



endmodule
`default_nettype wire
