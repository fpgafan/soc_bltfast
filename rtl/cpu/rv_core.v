// ============================================================================
// rv_core.v - Núcleo RV32IM_Zicsr segmentado en 6 etapas, pensado para Fmax
//
//   F1  : cálculo del siguiente PC -> dirección de la BSRAM de la icache
//   F2  : salida de la icache + comparación de etiqueta; pre-cálculo del
//         destino de saltos (PC + imm) y predicción estática (BTFN + JAL + RAS)
//   D   : decodificación, banco de registros (RAM distribuida), bypass de W,
//         selección de adelantamiento pre-calculada, interbloqueo carga-uso
//   E   : ALU, comparación de saltos, AGU -> dirección de la BSRAM de la dcache,
//         multiplicación / división (multiciclo, detiene solo D/E)
//   M   : salida de la dcache + etiqueta, alineación de cargas, stores
//         (dcache + buffer de stores), CSR, excepciones, MRET, FENCE
//   W   : escritura del banco de registros
//
// Filosofía para Fmax: ninguna señal "tardía" (acierto de caché) llega a las
// habilitaciones de todo el pipeline. Un fallo de la dcache, un acceso no
// cacheable o un buffer de stores lleno en M provocan un *replay*: la
// instrucción y las posteriores se anulan y se vuelve a buscar desde su PC
// (redirección registrada). D espera mientras la unidad de memoria está
// ocupada. Un fallo de la icache solo afecta a la búsqueda.
//
// Penalizaciones: salto predicho tomado 1 ciclo, fallo de predicción 3,
// carga-uso 1, store seguido de load 1, MUL 3, DIV ~34.
// ============================================================================
`default_nettype none
module rv_core #(
    parameter [31:0] RESET_PC = 32'h0000_0000
)(
    input  wire        clk,
    input  wire        rst,
    // ---------------- icache (lectura en F1/F2)
    output wire        ic_en,          // la BSRAM captura ic_addr en este flanco
    output wire [31:0] ic_addr,
    input  wire [31:0] ic_rdata,       // instrucción de la última dirección capturada
    input  wire        ic_hit,
    output reg         ic_fill_req,    // nivel hasta ic_fill_done
    output reg  [31:0] ic_fill_addr,
    input  wire        ic_fill_done,   // pulso
    output reg         ic_inval_req,   // FENCE.I: nivel hasta ic_inval_done
    input  wire        ic_inval_done,
    // ---------------- dcache (dirección en E, dato en M)
    output wire [31:0] dc_addr,
    input  wire [31:0] dc_rdata,
    input  wire        dc_hit,
    output wire [3:0]  dc_wbe,         // escritura de store (en M)
    output wire [31:0] dc_waddr,
    output wire [31:0] dc_wdata,
    // ---------------- unidad de memoria
    output wire        mreq,           // pulso: fallo de carga / carga no cacheable
    output wire [31:0] mreq_addr,
    output wire        mreq_fence,     // pulso: FENCE (vaciar SB + invalidar dcache)
    input  wire        mem_hold,       // la unidad de memoria atiende un replay
    input  wire        io_valid,       // dato de una carga no cacheable disponible
    input  wire [31:0] io_addr,
    input  wire [31:0] io_rdata,
    output wire        io_take,
    output wire        sb_push,
    output wire [31:0] sb_addr,
    output wire [31:0] sb_data,
    output wire [3:0]  sb_strb,
    input  wire        sb_full,
    // ---------------- interrupciones
    input  wire        irq_ext,
    input  wire        irq_timer,
    input  wire        irq_soft,
    // ---------------- depuración / medidas
    output wire [63:0] dbg_instret
);
    // ========================================================================
    // Constantes
    // ========================================================================
    localparam [6:0] OP_LUI = 7'b0110111, OP_AUIPC = 7'b0010111, OP_JAL = 7'b1101111,
                     OP_JALR = 7'b1100111, OP_BR = 7'b1100011, OP_LD = 7'b0000011,
                     OP_ST = 7'b0100011, OP_OPI = 7'b0010011, OP_OP = 7'b0110011,
                     OP_MISC = 7'b0001111, OP_SYS = 7'b1110011;

    // ========================================================================
    // Señales de redirección (todas registradas)
    // ========================================================================
    reg        redirect_q;          // fallo de predicción en E o flush en M
    reg [31:0] flush_pc_q, mis_pc_q;
    reg        flush_q;             // flush en M (anula también M)
    wire [31:0] redirect_pc_q = flush_q ? flush_pc_q : mis_pc_q;
    wire       kill_DE = redirect_q;   // anula D y E

    // ========================================================================
    // F1/F2: búsqueda
    // ========================================================================
    localparam F_RUN = 2'd0, F_FILL = 2'd1, F_INV = 2'd2, F_GO = 2'd3;
    reg [1:0]  fstate;
    reg [31:0] pcF;                 // dirección de la instrucción en F2
    reg [31:0] resume_pc;
    reg        fencei_pend;

    // D
    reg        vD;
    reg [31:0] irD, pcD, tgtD;
    reg        predD, doneD;

    wire       stallD;              // definido más abajo
    wire       fencei_commit;       // FENCE.I retirándose en M

    // predicción en D (registrada desde F2): salto hacia el destino pre-calculado
    wire d_redir = vD & predD & ~doneD & ~redirect_q;

    // RAS (pila de direcciones de retorno), 4 entradas
    reg [31:0] ras [0:3];
    reg [1:0]  ras_sp;
    wire [31:0] ras_top = ras[ras_sp];

    // pre-decodificación en F2
    wire [31:0] fi       = ic_rdata;
    wire        f_jal    = fi[6:0] == OP_JAL;
    wire        f_br     = fi[6:0] == OP_BR;
    wire        f_jalr   = fi[6:0] == OP_JALR;
    wire        f_ret    = f_jalr & (fi[19:15] == 5'd1 || fi[19:15] == 5'd5) & (fi[11:7] == 5'd0) &
                          (fi[31:20] == 12'd0);
    wire [31:0] f_immj   = {{12{fi[31]}}, fi[19:12], fi[20], fi[30:21], 1'b0};
    wire [31:0] f_immb   = {{20{fi[31]}}, fi[7], fi[30:25], fi[11:8], 1'b0};
    wire [31:0] f_tgt    = pcF + (fi[2] ? f_immj : f_immb);
    wire        f_pred   = f_jal | (f_br & fi[31]) | f_ret;

    // control de la búsqueda
    reg         f_en;
    reg  [31:0] f_next;
    wire        f2_ok    = (fstate == F_RUN) & ic_hit;
    // (un fallo arranca el relleno aunque D esté detenida: D conserva su instrucción)
    wire        f2_miss  = (fstate == F_RUN) & ~ic_hit & ~redirect_q & ~d_redir;

    always @(*) begin
        f_en   = 1'b0;
        f_next = pcF + 32'd4;
        case (fstate)
        F_RUN: begin
            if (redirect_q)      begin f_en = 1'b1; f_next = redirect_pc_q; end
            else if (d_redir)    begin f_en = 1'b1; f_next = tgtD; end
            else if (f2_miss)    f_en = 1'b0;
            else if (~stallD)    begin f_en = 1'b1; f_next = pcF + 32'd4; end
        end
        F_GO: begin
            f_en = 1'b1;
            if (redirect_q)      f_next = redirect_pc_q;
            else if (d_redir)    f_next = tgtD;
            else                 f_next = resume_pc;
        end
        default: ;
        endcase
    end
    assign ic_en   = f_en;
    assign ic_addr = f_next;

    always @(posedge clk) begin
        if (rst) begin
            fstate       <= F_GO;
            resume_pc    <= RESET_PC;
            pcF          <= RESET_PC;
            ic_fill_req  <= 1'b0;
            ic_inval_req <= 1'b0;
            fencei_pend  <= 1'b0;
        end else begin
            if (f_en) pcF <= f_next;
            case (fstate)
            F_RUN: begin
                if (fencei_commit) begin
                    fstate       <= F_INV;
                    ic_inval_req <= 1'b1;
                end else if (f2_miss) begin
                    fstate       <= F_FILL;
                    ic_fill_req  <= 1'b1;
                    ic_fill_addr <= pcF;
                    resume_pc    <= pcF;
                end
            end
            F_FILL, F_INV: begin
                if (redirect_q)   resume_pc <= redirect_pc_q;
                else if (d_redir) resume_pc <= tgtD;
                if (fencei_commit) begin
                    fencei_pend  <= 1'b1;
                    ic_inval_req <= 1'b1;
                end
                if (fstate == F_FILL && ic_fill_done) begin
                    ic_fill_req <= 1'b0;
                    fstate      <= (fencei_pend | fencei_commit) ? F_INV : F_GO;
                    fencei_pend <= 1'b0;
                end
                if (fstate == F_INV && ic_inval_done) begin
                    ic_inval_req <= 1'b0;
                    fstate       <= F_GO;
                end
            end
            F_GO: begin
                if (fencei_commit) begin
                    fstate       <= F_INV;
                    ic_inval_req <= 1'b1;
                end else
                    fstate <= F_RUN;
            end
            endcase
        end
    end

    // F2 -> D
    always @(posedge clk) begin
        if (rst) begin
            vD <= 1'b0; doneD <= 1'b0; predD <= 1'b0;
        end else if (redirect_q) begin
            vD <= 1'b0; doneD <= 1'b0; predD <= 1'b0;
        end else if (~stallD) begin
            vD    <= f2_ok & ~d_redir;
            irD   <= fi;
            pcD   <= pcF;
            tgtD  <= f_ret ? ras_top : f_tgt;
            predD <= f_pred;
            doneD <= 1'b0;
        end else if (d_redir)
            doneD <= 1'b1;
    end

    // ========================================================================
    // D: decodificación
    // ========================================================================
    wire [6:0] opD  = irD[6:0];
    wire [2:0] f3D  = irD[14:12];
    wire [6:0] f7D  = irD[31:25];
    wire [4:0] rdD  = irD[11:7];
    wire [4:0] rs1D = irD[19:15];
    wire [4:0] rs2D = irD[24:20];

    wire dLUI  = opD == OP_LUI;
    wire dAUI  = opD == OP_AUIPC;
    wire dJAL  = opD == OP_JAL;
    wire dJALR = opD == OP_JALR;
    wire dBR   = opD == OP_BR;
    wire dLD   = opD == OP_LD;
    wire dST   = opD == OP_ST;
    wire dOPI  = opD == OP_OPI;
    wire dOP   = opD == OP_OP;
    wire dMISC = opD == OP_MISC;
    wire dSYS  = opD == OP_SYS;

    wire dMD    = dOP & (f7D == 7'b0000001);
    wire dCSR   = dSYS & (f3D != 3'b000) & (f3D != 3'b100);
    wire dCSRI  = dCSR & f3D[2];
    wire dPRIV  = dSYS & (f3D == 3'b000);
    wire dECALL = dPRIV & (irD[31:20] == 12'h000);
    wire dEBRK  = dPRIV & (irD[31:20] == 12'h001);
    wire dMRET  = dPRIV & (irD[31:20] == 12'h302);
    wire dWFI   = dPRIV & (irD[31:20] == 12'h105);
    wire dFENCE = dMISC & (f3D == 3'b000);
    wire dFENCI = dMISC & (f3D == 3'b001);

    reg dLegal;
    always @(*) begin
        case (opD)
        OP_LUI, OP_AUIPC, OP_JAL: dLegal = 1'b1;
        OP_JALR:  dLegal = f3D == 3'b000;
        OP_BR:    dLegal = f3D != 3'b010 && f3D != 3'b011;
        OP_LD:    dLegal = f3D != 3'b011 && f3D != 3'b110 && f3D != 3'b111;
        OP_ST:    dLegal = f3D == 3'b000 || f3D == 3'b001 || f3D == 3'b010;
        OP_OPI:   dLegal = (f3D == 3'b001) ? (f7D == 7'b0) :
                           (f3D == 3'b101) ? (f7D == 7'b0 || f7D == 7'b0100000) : 1'b1;
        OP_OP:    dLegal = (f7D == 7'b0000001) || (f7D == 7'b0) ||
                           (f7D == 7'b0100000 && (f3D == 3'b000 || f3D == 3'b101));
        OP_MISC:  dLegal = f3D == 3'b000 || f3D == 3'b001;
        OP_SYS:   dLegal = dCSR | dECALL | dEBRK | dMRET | dWFI;
        default:  dLegal = 1'b0;
        endcase
    end

    wire [31:0] immI = {{20{irD[31]}}, irD[31:20]};
    wire [31:0] immS = {{20{irD[31]}}, irD[31:25], irD[11:7]};
    wire [31:0] immU = {irD[31:12], 12'b0};

    wire rs1_used = dJALR | dBR | dLD | dST | dOPI | dOP | (dCSR & ~dCSRI);
    wire rs2_used = dBR | dST | dOP;
    wire use_imm  = dOPI | dLUI | dAUI;
    wire d_we     = (dLUI | dAUI | dJAL | dJALR | dLD | dOPI | dOP | dCSR) & (rdD != 5'd0);
    wire d_late   = dLD | dCSR;                      // resultado disponible al final de M
    wire d_sub    = (dOP & f7D[5] & (f3D == 3'b000)) |
                    ((dOP | dOPI) & (f3D == 3'b010 || f3D == 3'b011)) | dBR;

    // banco de registros: dos copias en RAM distribuida (lectura asíncrona)
    reg  [31:0] rf1 [0:31] /* synthesis syn_ramstyle = "distributed_ram" */;
    reg  [31:0] rf2 [0:31] /* synthesis syn_ramstyle = "distributed_ram" */;
    reg         vW, weW;
    reg  [4:0]  rdW;
    reg  [31:0] resW;
    wire        rf_we = vW & weW;
    integer k;
    initial for (k = 0; k < 32; k = k + 1) begin rf1[k] = 32'd0; rf2[k] = 32'd0; end
    always @(posedge clk) if (rf_we) begin
        rf1[rdW] <= resW;
        rf2[rdW] <= resW;
    end
    wire [31:0] r1raw = rf1[rs1D];
    wire [31:0] r2raw = rf2[rs2D];
    wire [31:0] r1 = (rs1D == 5'd0) ? 32'd0 : (rf_we && rdW == rs1D) ? resW : r1raw;
    wire [31:0] r2 = (rs2D == 5'd0) ? 32'd0 : (rf_we && rdW == rs2D) ? resW : r2raw;

    // ========================================================================
    // Registros de E y M (declaración)
    // ========================================================================
    reg        vE, weE, lateE, ldE, stE, brE, jalrE, linkE, mdE, csrE, subE, sraE;
    reg        excE, irqE, mretE, fenceE, fenciE;
    reg [3:0]  causeE;
    reg [2:0]  f3E;
    reg        s_add, s_sll, s_slt, s_sltu, s_xor, s_sr, s_or, s_and, s_x;
    reg [4:0]  rdE;
    reg [31:0] pcE, pc4E, tgtE, opaE, opbE, immE;
    reg        predE, rpushE, rpopE;
    reg        fAM, fAW, fBM, fBW;

    reg        vM, weM, lateM, ldM, stM, csrM, cacheM;
    reg        excM, irqM, mretM, fenceM, fenciM;
    reg [3:0]  causeM;
    reg [2:0]  f3M;
    reg [4:0]  rdM;
    reg [31:0] pcM, resM, addrM, sdM;
    reg [11:0] csraM;

    // ========================================================================
    // D: interbloqueos y adelantamiento
    // ========================================================================
    wire md_done;
    wire stallE = vE & mdE & ~md_done & ~kill_DE;

    wire loaduse = vE & lateE & weE &
                   ((rs1_used & (rdE == rs1D)) | (rs2_used & (rdE == rs2D)));
    wire st_ld   = vE & stE & dLD;
    wire st_csr  = ((vE & csrE) | (vM & csrM)) & dCSR;   // CSR tras CSR: el anterior escribe en M
    assign stallD = stallE | (vD & (loaduse | st_ld | st_csr | mem_hold));

    // interrupción: se inyecta sustituyendo a la instrucción que pasa a E
    reg  irq_q;
    wire inject = irq_q & ~io_valid & ~mem_hold;
    wire issue  = vD & ~stallD & ~kill_DE;

    wire prodE = vE & weE & ~lateE;
    wire prodM = vM & weM;
    wire nfAM  = rs1_used & prodE & (rdE == rs1D);
    wire nfAW  = rs1_used & prodM & (rdM == rs1D) & ~nfAM;
    wire nfBM  = rs2_used & ~use_imm & prodE & (rdE == rs2D);
    wire nfBW  = rs2_used & ~use_imm & prodM & (rdM == rs2D) & ~nfBM;

    // RAS: push en llamadas, pop en retornos (al emitir)
    wire d_link = (dJAL | dJALR) & (rdD == 5'd1 || rdD == 5'd5);
    wire d_ret  = dJALR & (rs1D == 5'd1 || rs1D == 5'd5) & (rdD == 5'd0);
    wire [31:0] pc4D = pcD + 32'd4;
    always @(posedge clk) begin
        if (rst) begin
            ras_sp <= 2'd0;
            ras[0] <= RESET_PC; ras[1] <= RESET_PC; ras[2] <= RESET_PC; ras[3] <= RESET_PC;
        end else if (vE & ~kill_DE & ~irqE) begin       // se actualiza desde E (registrado)
            if (rpushE) begin
                ras[ras_sp + 2'd1] <= pc4E;
                ras_sp <= ras_sp + 2'd1;
            end else if (rpopE)
                ras_sp <= ras_sp - 2'd1;
        end
    end

    // D -> E
    always @(posedge clk) begin
        if (rst) begin
            vE <= 1'b0;
        end else if (~stallE) begin
            vE <= issue;
            begin
                pcE    <= pcD;
                pc4E   <= pc4D;
                tgtE   <= tgtD;
                predE  <= predD;
                rpushE <= d_link & dLegal & ~inject;
                rpopE  <= d_ret & ~d_link & dLegal & ~inject;
                rdE    <= rdD;
                f3E    <= f3D;
                immE   <= dST ? immS : immI;
                opaE   <= (dAUI) ? pcD : (dLUI) ? 32'd0 : dCSRI ? {27'd0, rs1D} : r1;
                opbE   <= dCSR ? 32'd0 : use_imm ? (dLUI | dAUI ? immU : immI) : r2;   // CSR: a + 0
                fAM    <= nfAM;  fAW <= nfAW;  fBM <= nfBM;  fBW <= nfBW;
                s_x    <= dJAL | dJALR | dMD;
                s_add  <= ~(dJAL | dJALR | dMD) & (~(dOP | dOPI) | f3D == 3'b000);
                s_sll  <= (dOP | dOPI) & ~dMD & (f3D == 3'b001);
                s_slt  <= (dOP | dOPI) & ~dMD & (f3D == 3'b010);
                s_sltu <= (dOP | dOPI) & ~dMD & (f3D == 3'b011);
                s_xor  <= (dOP | dOPI) & ~dMD & (f3D == 3'b100);
                s_sr   <= (dOP | dOPI) & ~dMD & (f3D == 3'b101);
                s_or   <= (dOP | dOPI) & ~dMD & (f3D == 3'b110);
                s_and  <= (dOP | dOPI) & ~dMD & (f3D == 3'b111);
                subE   <= d_sub;
                sraE   <= f7D[5];
                if (inject | ~dLegal) begin
                    weE <= 1'b0; lateE <= 1'b0; ldE <= 1'b0; stE <= 1'b0; brE <= 1'b0;
                    jalrE <= 1'b0; linkE <= 1'b0; mdE <= 1'b0; csrE <= 1'b0;
                    mretE <= 1'b0; fenceE <= 1'b0; fenciE <= 1'b0;
                    irqE  <= inject;
                    excE  <= ~inject;
                    causeE <= 4'd2;                     // instrucción ilegal
                end else begin
                    weE    <= d_we;
                    lateE  <= d_late;
                    ldE    <= dLD;
                    stE    <= dST;
                    brE    <= dBR;
                    jalrE  <= dJALR;
                    linkE  <= dJAL | dJALR;
                    mdE    <= dMD;
                    csrE   <= dCSR;
                    mretE  <= dMRET;
                    fenceE <= dFENCE;
                    fenciE <= dFENCI;
                    irqE   <= 1'b0;
                    excE   <= dECALL | dEBRK;
                    causeE <= dECALL ? 4'd11 : 4'd3;
                end
            end
        end else if (kill_DE)
            vE <= 1'b0;
    end

    // ========================================================================
    // E: ejecución
    // ========================================================================
    // Adelantamiento: copias separadas por consumidor (menos carga y rutado)
    wire [31:0] a  /* synthesis syn_keep=1 */;      // ALU, CSR, mul/div
    wire [31:0] b  /* synthesis syn_keep=1 */;
    wire [31:0] ac /* synthesis syn_keep=1 */;      // comparación de saltos / JALR
    wire [31:0] bc /* synthesis syn_keep=1 */;
    wire [31:0] aa /* synthesis syn_keep=1 */;      // AGU
    assign a  = fAM ? resM : fAW ? resW : opaE;
    assign b  = fBM ? resM : fBW ? resW : opbE;
    assign ac = fAM ? resM : fAW ? resW : opaE;
    assign bc = fBM ? resM : fBW ? resW : opbE;
    assign aa = fAM ? resM : fAW ? resW : opaE;

    // ALU
    wire [32:0] sum33 = {1'b0, a} + {1'b0, b ^ {32{subE}}} + {32'd0, subE};
    wire [31:0] sum   = sum33[31:0];
    wire        ltu   = ~sum33[32];                    // a - b con préstamo
    wire        lt    = (a[31] ^ b[31]) ? a[31] : sum[31];
    wire [31:0] sll   = a << b[4:0];
    wire [31:0] srx   = $signed({sraE & a[31], a}) >>> b[4:0];

    // comparador de saltos propio
    wire [32:0] cmp33 = {1'b0, ac} - {1'b0, bc};
    wire        c_ltu = cmp33[32];
    wire        c_lt  = (ac[31] ^ bc[31]) ? ac[31] : cmp33[31];
    wire        c_eq  = (ac == bc);

    // resultado: AND-OR con selecciones one-hot registradas
    wire [31:0] md_res;
    wire [31:0] xres = linkE ? pc4E : md_res;
    wire [31:0] resE = ({32{s_add}}  & sum) |
                       ({32{s_sll}}  & sll) |
                       ({32{s_slt}}  & {31'd0, lt}) |
                       ({32{s_sltu}} & {31'd0, ltu}) |
                       ({32{s_xor}}  & (a ^ b)) |
                       ({32{s_sr}}   & srx) |
                       ({32{s_or}}   & (a | b)) |
                       ({32{s_and}}  & (a & b)) |
                       ({32{s_x}}    & xres);

    wire [31:0] agu = aa + immE;
    assign dc_addr  = agu;

    // muldiv
    wire md_start = vE & mdE & ~kill_DE;
    rv_muldiv u_md (
        .clk(clk), .rst(rst), .start(md_start), .kill(kill_DE), .op(f3E),
        .a(a), .b(b), .done(md_done), .res(md_res)
    );

    // saltos
    reg taken;
    always @(*) begin
        case (f3E)
        3'b000: taken = c_eq;
        3'b001: taken = ~c_eq;
        3'b100: taken = c_lt;
        3'b101: taken = ~c_lt;
        3'b110: taken = c_ltu;
        default: taken = ~c_ltu;
        endcase
    end
    wire [31:0] jtgt   = {agu[31:1], 1'b0};
    wire        liveE  = vE & ~kill_DE;
    wire        mis_br = brE & (taken ^ predE);
    // solo se predicen retornos con imm = 0: basta comparar rs1 con el destino
    wire        mis_jr = jalrE & (~predE | (tgtE[31:1] != ac[31:1]));
    wire        mispredict = liveE & (mis_br | mis_jr);
    // en un fallo de predicción de bifurcación el destino es el contrario al predicho
    wire [31:0] mis_pc = jalrE ? jtgt : (predE ? pc4E : tgtE);

    // desalineación
    wire misal = (f3E[1:0] == 2'b10 && agu[1:0] != 2'b00) ||
                 (f3E[1:0] == 2'b01 && agu[0]);
    wire cacheable = (agu[31:28] == 4'h0) || (agu[31:28] == 4'h4);


    // E -> M
    always @(posedge clk) begin
        if (rst) begin
            vM <= 1'b0;
        end else begin
            vM <= liveE & ~stallE;
            pcM    <= pcE;
            resM   <= resE;
            addrM  <= agu;
            sdM    <= b;
            rdM    <= rdE;
            weM    <= weE;
            lateM  <= lateE;
            ldM    <= ldE;
            stM    <= stE;
            csrM   <= csrE;
            cacheM <= cacheable;
            f3M    <= f3E;
            csraM  <= immE[11:0];
            irqM   <= irqE;
            mretM  <= mretE;
            fenceM <= fenceE;
            fenciM <= fenciE;
            if ((ldE | stE) & misal & ~excE) begin
                excM   <= 1'b1;
                causeM <= ldE ? 4'd4 : 4'd6;
            end else begin
                excM   <= excE;
                causeM <= causeE;
            end
        end
    end

    // ========================================================================
    // M: memoria, CSR, excepciones
    // ========================================================================
    wire        liveM    = vM & ~flush_q;
    // el primer load no cacheable que llega a M tras el replay es el que pidió el dato
    wire        io_match = io_valid & ~cacheM;
    wire        ld_ok    = cacheM ? dc_hit : io_match;
    wire [31:0] lword    = io_match ? io_rdata : dc_rdata;
    wire [31:0] lsh      = lword >> {addrM[1:0], 3'b000};
    reg  [31:0] ldata;
    always @(*) begin
        case (f3M)
        3'b000: ldata = {{24{lsh[7]}},  lsh[7:0]};
        3'b001: ldata = {{16{lsh[15]}}, lsh[15:0]};
        3'b100: ldata = {24'd0, lsh[7:0]};
        3'b101: ldata = {16'd0, lsh[15:0]};
        default: ldata = lsh;
        endcase
    end

    // CSR
    reg        mstatus_mie, mstatus_mpie;
    reg        mie_meie, mie_mtie, mie_msie;
    reg [31:0] mtvec, mscratch, mepc, mtval;
    reg [31:0] mcause;
    // contadores de 64 bits en dos mitades con acarreo registrado (la parte alta
    // se actualiza un ciclo después: leer alta-baja-alta como siempre)
    reg [31:0] mcyc_l, mcyc_h, mins_l, mins_h;
    reg        mcyc_c, mins_c;
    wire [63:0] mcycle   = {mcyc_h, mcyc_l};
    wire [63:0] minstret = {mins_h, mins_l};
    assign dbg_instret = minstret;

    wire [31:0] mip = {20'd0, irq_ext, 3'd0, irq_timer, 3'd0, irq_soft, 3'd0};
    wire [31:0] mie = {20'd0, mie_meie, 3'd0, mie_mtie, 3'd0, mie_msie, 3'd0};
    wire        irq_now = mstatus_mie & ((irq_ext & mie_meie) | (irq_timer & mie_mtie) | (irq_soft & mie_msie));
    wire [3:0]  irq_cause = (irq_ext & mie_meie) ? 4'd11 : (irq_soft & mie_msie) ? 4'd3 : 4'd7;

    // El CSR se lee en E (dirección = immE) y el valor pasa registrado a M.
    // Dos instrucciones CSR seguidas se separan una burbuja (ver st_csr).
    reg [31:0] csr_r, csr_rq;
    always @(posedge clk) csr_rq <= csr_r;
    always @(*) begin
        case (immE[11:0])
        12'h300: csr_r = {19'd0, 2'b11, 3'd0, mstatus_mpie, 3'd0, mstatus_mie, 3'd0};
        12'h301: csr_r = 32'h4000_1100;               // RV32IM
        12'h304: csr_r = mie;
        12'h305: csr_r = mtvec;
        12'h340: csr_r = mscratch;
        12'h341: csr_r = mepc;
        12'h342: csr_r = mcause;
        12'h343: csr_r = mtval;
        12'h344: csr_r = mip;
        12'hB00, 12'hC00, 12'hC01: csr_r = mcycle[31:0];
        12'hB80, 12'hC80, 12'hC81: csr_r = mcycle[63:32];
        12'hB02, 12'hC02: csr_r = minstret[31:0];
        12'hB82, 12'hC82: csr_r = minstret[63:32];
        default: csr_r = 32'd0;                       // mhartid, mvendorid... = 0
        endcase
    end
    wire [31:0] csr_src = resM;                       // rs1 o zimm (pasado por E)
    reg  [31:0] csr_w;
    always @(*) begin
        case (f3M[1:0])
        2'b01:   csr_w = csr_src;
        2'b10:   csr_w = csr_rq | csr_src;
        default: csr_w = csr_rq & ~csr_src;
        endcase
    end
    // CSRRS/CSRRC con rs1 = x0 / zimm = 0 no escriben
    wire csr_wr_en = (f3M[1:0] == 2'b01) | (csr_src != 32'd0);

    wire replay  = liveM & ~excM & ((ldM & ~ld_ok) | (stM & sb_full) | (irqM & ~irq_now));
    wire trap    = liveM & (excM | (irqM & irq_now));
    wire do_mret = liveM & mretM;
    wire do_fen  = liveM & (fenceM | fenciM);
    assign fencei_commit = liveM & fenciM;
    wire flush_n = replay | trap | do_mret | do_fen;
    wire [31:0] flush_pc_n = trap ? {mtvec[31:2], 2'b00} : do_mret ? mepc :
                             do_fen ? pcM + 32'd4 : pcM;

    assign mreq       = liveM & ~excM & ldM & ~ld_ok;
    assign mreq_addr  = addrM;
    assign mreq_fence = liveM & fenceM;
    assign io_take    = liveM & ~excM & ldM & io_match;

    // stores
    reg [31:0] st_data;
    reg [3:0]  st_strb;
    always @(*) begin
        case (f3M[1:0])
        2'b00:   begin st_data = {4{sdM[7:0]}};  st_strb = 4'b0001 << addrM[1:0]; end
        2'b01:   begin st_data = {2{sdM[15:0]}}; st_strb = addrM[1] ? 4'b1100 : 4'b0011; end
        default: begin st_data = sdM;            st_strb = 4'b1111; end
        endcase
    end
    wire st_commit = liveM & stM & ~excM & ~sb_full;
    assign sb_push  = st_commit;
    assign sb_addr  = addrM;
    assign sb_data  = st_data;
    assign sb_strb  = st_strb;
    assign dc_wbe   = (st_commit & cacheM & dc_hit) ? st_strb : 4'b0000;
    assign dc_waddr = addrM;
    assign dc_wdata = st_data;

    // redirección
    always @(posedge clk) begin
        if (rst) begin
            redirect_q <= 1'b0;
            flush_q    <= 1'b0;
        end else begin
            flush_q    <= flush_n;
            redirect_q <= flush_n | mispredict;
            flush_pc_q <= flush_pc_n;   // selección temprana (no depende de aciertos)
            mis_pc_q   <= mis_pc;
        end
    end

    // CSR / trap
    always @(posedge clk) begin
        if (rst) begin
            mstatus_mie <= 1'b0; mstatus_mpie <= 1'b0;
            mie_meie <= 1'b0; mie_mtie <= 1'b0; mie_msie <= 1'b0;
            mtvec <= 32'd0; mepc <= 32'd0; mcause <= 32'd0; mtval <= 32'd0;
            mscratch <= 32'd0;
            mcyc_l <= 32'd0; mcyc_h <= 32'd0; mins_l <= 32'd0; mins_h <= 32'd0;
            mcyc_c <= 1'b0; mins_c <= 1'b0;
            irq_q <= 1'b0;
        end else begin
            mcyc_l <= mcyc_l + 32'd1;
            mcyc_c <= (mcyc_l == 32'hFFFF_FFFE);
            if (mcyc_c) mcyc_h <= mcyc_h + 32'd1;
            if (vW) mins_l <= mins_l + 32'd1;
            mins_c <= vW & (mins_l == 32'hFFFF_FFFF);
            if (mins_c) mins_h <= mins_h + 32'd1;
            irq_q <= irq_now;
            if (trap) begin
                mepc         <= pcM;
                mcause       <= {irqM & ~excM, 27'd0, (irqM & ~excM) ? irq_cause : causeM};
                mtval        <= (causeM == 4'd4 || causeM == 4'd6) & excM ? addrM : 32'd0;
                mstatus_mpie <= mstatus_mie;
                mstatus_mie  <= 1'b0;
            end else if (do_mret) begin
                mstatus_mie  <= mstatus_mpie;
                mstatus_mpie <= 1'b1;
            end else if (liveM & csrM & ~excM & csr_wr_en) begin
                case (csraM)
                12'h300: begin mstatus_mie <= csr_w[3]; mstatus_mpie <= csr_w[7]; end
                12'h304: begin mie_meie <= csr_w[11]; mie_mtie <= csr_w[7]; mie_msie <= csr_w[3]; end
                12'h305: mtvec    <= csr_w;
                12'h340: mscratch <= csr_w;
                12'h341: mepc     <= {csr_w[31:2], 2'b00};
                12'h342: mcause   <= csr_w;
                12'h343: mtval    <= csr_w;
                12'hB00: mcyc_l <= csr_w;
                12'hB80: mcyc_h <= csr_w;
                12'hB02: mins_l <= csr_w;
                12'hB82: mins_h <= csr_w;
                default: ;
                endcase
            end
        end
    end

    // M -> W
    always @(posedge clk) begin
        if (rst) begin
            vW <= 1'b0; weW <= 1'b0;
        end else begin
            vW   <= liveM & ~replay & ~trap;
            weW  <= weM & liveM & ~replay & ~trap;
            rdW  <= rdM;
            resW <= ldM ? ldata : csrM ? csr_rq : resM;
        end
    end

endmodule
`default_nettype wire
