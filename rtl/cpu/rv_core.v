// ============================================================================
// rv_core.v - 6-stage pipelined RV32IM_Zicsr_Zba_Zbb core, designed for Fmax
//
//   F1  : next-PC computation -> icache BSRAM address
//   F2  : icache output + tag compare; precomputation of the
//         branch target (PC + imm) and prediction: JAL, returns (RAS),
//         branches (BTFN corrected by a table of 256 "disagree" counters)
//         and indirect JALR with imm = 0 (table of 32 last targets)
//   D   : decode, register file (distributed RAM), W bypass,
//         precomputed forwarding select, load-use interlock
//   E   : ALU, branch compare, AGU -> dcache BSRAM address,
//         multiply / divide (multicycle, stalls only D/E)
//   M   : dcache output + tag, load alignment, stores
//         (dcache + store buffer), CSR, exceptions, MRET, FENCE,
//         the slow Zba/Zbb operations (shNadd orc.b rev8 rol ror min max:
//         result at the end of M like a load). clz/ctz/cpop: multicycle in
//         rv_muldiv
//   W   : register file write-back
//
// Fmax philosophy: no "late" signal (cache hit) reaches the enables of
// the whole pipeline. A dcache miss, an uncacheable access or a full
// store buffer in M cause a *replay*: the instruction and the
// following ones are squashed and fetching restarts from its PC
// (registered redirect). D waits while the memory unit is
// busy. An icache miss only affects fetch.
//
// Penalties: predicted-taken branch 1 cycle, misprediction 3,
// load-use 1 (also after a slow Zba/Zbb operation), store followed by load 1,
// MUL 3, DIV ~34, clz/ctz ~4-12, cpop 9.
// ============================================================================
`default_nettype none
module rv_core #(
    parameter [31:0] RESET_PC = 32'h0000_0000
)(
    input  wire        clk,
    input  wire        rst,
    // ---------------- icache (read in F1/F2)
    output wire        ic_en,          // the BSRAM latches ic_addr on this edge
    output wire [31:0] ic_addr,
    input  wire [31:0] ic_rdata,       // instruction at the last latched address
    input  wire        ic_hit,
    output reg         ic_fill_req,    // level until ic_fill_done
    output reg  [31:0] ic_fill_addr,
    input  wire        ic_fill_done,   // pulse
    output reg         ic_inval_req,   // FENCE.I: level until ic_inval_done
    input  wire        ic_inval_done,
    // ---------------- dcache (address in E, data in M)
    output wire [31:0] dc_addr,
    input  wire [31:0] dc_rdata,
    input  wire        dc_hit,
    output wire [3:0]  dc_wbe,         // store write (in M)
    output wire [31:0] dc_waddr,
    output wire [31:0] dc_wdata,
    // ---------------- memory unit
    output wire        mreq,           // pulse: load miss / uncacheable load
    output wire [31:0] mreq_addr,
    output wire        mreq_fence,     // pulse: FENCE (drain SB + invalidate dcache)
    input  wire        mem_hold,       // the memory unit is serving a replay
    input  wire        io_valid,       // data of an uncacheable load available
    input  wire [31:0] io_addr,
    input  wire [31:0] io_rdata,
    output wire        io_take,
    output wire        sb_push,
    output wire [31:0] sb_addr,
    output wire [31:0] sb_data,
    output wire [3:0]  sb_strb,
    input  wire        sb_full,
    // ---------------- interrupts
    input  wire        irq_ext,
    input  wire        irq_timer,
    input  wire        irq_soft,
    // ---------------- debug / measurements
    output wire [63:0] dbg_instret
);
    // ========================================================================
    // Constants
    // ========================================================================
    localparam [6:0] OP_LUI = 7'b0110111, OP_AUIPC = 7'b0010111, OP_JAL = 7'b1101111,
                     OP_JALR = 7'b1100111, OP_BR = 7'b1100011, OP_LD = 7'b0000011,
                     OP_ST = 7'b0100011, OP_OPI = 7'b0010011, OP_OP = 7'b0110011,
                     OP_MISC = 7'b0001111, OP_SYS = 7'b1110011;

    // ========================================================================
    // Redirect signals (all registered)
    // ========================================================================
    reg        redirect_q;          // misprediction in E or flush in M
    reg [31:0] flush_pc_q, mis_pc_q;
    reg        flush_q;             // flush in M (also squashes M)
    wire [31:0] redirect_pc_q = flush_q ? flush_pc_q : mis_pc_q;
    wire       kill_DE = redirect_q;   // squashes D and E

    // ========================================================================
    // F1/F2: fetch
    // ========================================================================
    localparam F_RUN = 2'd0, F_FILL = 2'd1, F_INV = 2'd2, F_GO = 2'd3;
    reg [1:0]  fstate;
    reg [31:0] pcF;                 // address of the instruction in F2
    reg [31:0] resume_pc;
    reg        fencei_pend;

    // D
    reg        vD;
    reg [31:0] irD, pcD, tgtD;
    reg        predD, doneD;
    reg [1:0]  ctrD;                // counter read for the branch in D

    wire       stallD;              // defined below
    wire       fencei_commit;       // FENCE.I retiring in M

    // prediction in D (registered from F2): jump to the precomputed target
    wire d_redir = vD & predD & ~doneD & ~redirect_q;

    // RAS (return address stack), 4 entries
    reg [31:0] ras [0:3];
    reg [1:0]  ras_sp;
    wire [31:0] ras_top = ras[ras_sp];

    // branch predictor (distributed RAM, asynchronous read with pcF in F2):
    //   bht: 2-bit counter per branch (index pc[9:2]) of how much the branch
    //        disagrees with the static prediction (backward taken); starts at 0
    //   jt:  last target of the indirect JALR (imm = 0, not returns), pc[6:2]
    reg  [1:0]  bht [0:255] /* synthesis syn_ramstyle = "distributed_ram" */;
    // jt entry: {target[30], target[22:1], valid} (code is in the ROM or the SDRAM)
    reg  [23:0] jt  [0:31]  /* synthesis syn_ramstyle = "distributed_ram" */;
    integer bi;
    initial begin
        for (bi = 0; bi < 256; bi = bi + 1) bht[bi] = 2'd0;
        for (bi = 0; bi < 32; bi = bi + 1) jt[bi] = 24'd0;
    end
    wire [1:0]  f_ctr = bht[pcF[9:2]];
    wire [23:0] f_jt  = jt[pcF[6:2]];

    // predecode in F2
    wire [31:0] fi       = ic_rdata;
    wire        f_jal    = fi[6:0] == OP_JAL;
    wire        f_br     = fi[6:0] == OP_BR;
    wire        f_jalr   = fi[6:0] == OP_JALR;
    wire        f_ret    = f_jalr & (fi[19:15] == 5'd1 || fi[19:15] == 5'd5) & (fi[11:7] == 5'd0) &
                          (fi[31:20] == 12'd0);
    wire [31:0] f_immj   = {{12{fi[31]}}, fi[19:12], fi[20], fi[30:21], 1'b0};
    wire [31:0] f_immb   = {{20{fi[31]}}, fi[7], fi[30:25], fi[11:8], 1'b0};
    wire [31:0] f_tgt    = pcF + (fi[2] ? f_immj : f_immb);
    wire        f_jind   = f_jalr & ~f_ret & (fi[31:20] == 12'd0) & f_jt[0];
    wire        f_pred   = f_jal | (f_br & (fi[31] ^ f_ctr[1])) | f_ret | f_jind;

    // fetch control
    reg         f_en;
    reg  [31:0] f_next;
    wire        f2_ok    = (fstate == F_RUN) & ic_hit;
    // (a miss starts the refill even if D is stalled: D keeps its instruction)
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

    // legality of the instruction, decoded in F2 (off the D -> E path)
    function rv_legal(input [31:0] ir);
        reg [6:0] op, f7;
        reg [2:0] f3;
        reg [4:0] r2;
        reg [11:0] i12;
        reg       un, csr;
        begin
            op = ir[6:0]; f3 = ir[14:12]; f7 = ir[31:25]; r2 = ir[24:20]; i12 = ir[31:20];
            un  = (f7 == 7'b0110000) & (r2 == 5'd0 || r2 == 5'd1 || r2 == 5'd2 || r2 == 5'd4 || r2 == 5'd5);
            csr = (f3 != 3'b000) & (f3 != 3'b100);
            case (op)
            OP_LUI, OP_AUIPC, OP_JAL: rv_legal = 1'b1;
            OP_JALR:  rv_legal = f3 == 3'b000;
            OP_BR:    rv_legal = f3 != 3'b010 && f3 != 3'b011;
            OP_LD:    rv_legal = f3 != 3'b011 && f3 != 3'b110 && f3 != 3'b111;
            OP_ST:    rv_legal = f3 == 3'b000 || f3 == 3'b001 || f3 == 3'b010;
            OP_OPI:   rv_legal = (f3 == 3'b001) ? (f7 == 7'b0) | un :
                                 (f3 == 3'b101) ? (f7 == 7'b0 || f7 == 7'b0100000 || f7 == 7'b0110000 ||
                                                   i12 == 12'h287 || i12 == 12'h698) : 1'b1;
            OP_OP:    rv_legal = (f7 == 7'b0000001) || (f7 == 7'b0) ||
                                 (f7 == 7'b0100000 && (f3 == 3'b000 || f3 == 3'b101 || f3[2])) ||
                                 (f7 == 7'b0010000 && (f3 == 3'b010 || f3 == 3'b100 || f3 == 3'b110)) ||
                                 (f7 == 7'b0000101 && f3[2]) ||
                                 (f7 == 7'b0110000 && (f3 == 3'b001 || f3 == 3'b101)) ||
                                 (f7 == 7'b0000100 && f3 == 3'b100 && r2 == 5'd0);
            OP_MISC:  rv_legal = f3 == 3'b000 || f3 == 3'b001;
            OP_SYS:   rv_legal = csr | (f3 == 3'b000 && (i12 == 12'h000 || i12 == 12'h001 ||
                                                         i12 == 12'h302 || i12 == 12'h105));
            default:  rv_legal = 1'b0;
            endcase
        end
    endfunction
    reg legalD;

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
            tgtD  <= f_ret ? ras_top : f_jind ? {1'b0, f_jt[23], 7'd0, f_jt[22:1], 1'b0} : f_tgt;
            predD <= f_pred;
            ctrD  <= f_ctr;
            legalD <= rv_legal(fi);
            doneD <= 1'b0;
        end else if (d_redir)
            doneD <= 1'b1;
    end

    // ========================================================================
    // D: decode
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
    // Zba / Zbb
    wire [11:0] i12D = irD[31:20];
    wire zShadd = dOP & (f7D == 7'b0010000) & (f3D == 3'b010 || f3D == 3'b100 || f3D == 3'b110);
    wire zInv   = dOP & (f7D == 7'b0100000) & (f3D == 3'b100 || f3D == 3'b110 || f3D == 3'b111);
    wire zMinMx = dOP & (f7D == 7'b0000101) & f3D[2];
    wire zRot   = (dOP & (f7D == 7'b0110000) & (f3D == 3'b001 || f3D == 3'b101)) |
                  (dOPI & (f7D == 7'b0110000) & (f3D == 3'b101));
    wire zUn    = dOPI & (f3D == 3'b001) & (f7D == 7'b0110000);
    wire zClz   = zUn & (rs2D == 5'd0);
    wire zCtz   = zUn & (rs2D == 5'd1);
    wire zCpop  = zUn & (rs2D == 5'd2);
    wire zSextB = zUn & (rs2D == 5'd4);
    wire zSextH = zUn & (rs2D == 5'd5);
    wire zOrcB  = dOPI & (f3D == 3'b101) & (i12D == 12'h287);
    wire zRev8  = dOPI & (f3D == 3'b101) & (i12D == 12'h698);
    wire zZextH = dOP & (f7D == 7'b0000100) & (f3D == 3'b100) & (rs2D == 5'd0);
    wire zLate  = zMinMx | zRot | zOrcB | zRev8 | zShadd;               // computed in M
    wire zCnt   = zClz | zCtz | zCpop;                                  // multicycle (rv_muldiv)
    wire zExt   = zSextB | zSextH | zZextH;                            // one term in E
    wire dALU   = (dOP | dOPI) & ~dMD & ~zLate & ~zExt & ~zCnt;       // base ALU (+ andn/orn/xnor)

    wire dFENCE = dMISC & (f3D == 3'b000);
    wire dFENCI = dMISC & (f3D == 3'b001);

    wire dLegal = legalD;

    wire [31:0] immI = {{20{irD[31]}}, irD[31:20]};
    wire [31:0] immS = {{20{irD[31]}}, irD[31:25], irD[11:7]};
    wire [31:0] immU = {irD[31:12], 12'b0};

    wire rs1_used = dJALR | dBR | dLD | dST | dOPI | dOP | (dCSR & ~dCSRI);
    wire rs2_used = dBR | dST | dOP;
    wire use_imm  = dOPI | dLUI | dAUI;
    wire d_we     = (dLUI | dAUI | dJAL | dJALR | dLD | dOPI | dOP | dCSR) & (rdD != 5'd0);
    wire d_late   = dLD | dCSR | zLate;              // result available at the end of M
    // (min/max compare in the ALU: lt/ltu go to M)
    wire d_sub    = (dOP & f7D[5] & (f3D == 3'b000)) |
                    ((dOP | dOPI) & (f3D == 3'b010 || f3D == 3'b011) & ~zShadd) | dBR | zMinMx;

    // register file: two copies in distributed RAM (asynchronous read)
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
    // E and M registers (declaration)
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
    // Zba/Zbb in E: shNadd (operand a already shifted, one-hot selects of its
    // source: M, W or the register read in D), extensions, inverted b
    reg        s_ext, e_b, e_h, binvE, xbE, jtE;
    reg        sh1E, sh2E, sh3E;          // shNadd: n
    reg [1:0]  cntE;                      // clz 01 / ctz 10 / cpop 11 (rv_muldiv)
    // slow operation (one-hot, for M)
    reg        x_orcE, x_revE, x_rotE, x_rolE, x_mmE;
    reg [1:0]  ctrE;
    reg        hintE;                    // static prediction of the branch (backward)

    reg        vM, weM, lateM, ldM, stM, csrM, cacheM;
    reg        excM, irqM, mretM, fenceM, fenciM;
    reg [3:0]  causeM;
    reg [2:0]  f3M;
    reg [4:0]  rdM;
    reg [31:0] pcM, resM, addrM, sdM;
    reg [11:0] csraM;
    reg        xbM, x_orcM, x_revM, x_rotM, x_mmM, x_selaM, sh1M, sh2M, sh3M;
    reg [4:0]  x_shM;
    reg [31:0] aM;

    // ========================================================================
    // D: interlocks and forwarding
    // ========================================================================
    wire md_done;
    wire stallE = vE & mdE & ~md_done & ~kill_DE;

    wire loaduse = vE & lateE & weE &
                   ((rs1_used & (rdE == rs1D)) | (rs2_used & (rdE == rs2D)));
    wire st_ld   = vE & stE & dLD;
    wire st_csr  = ((vE & csrE) | (vM & csrM)) & dCSR;   // CSR after CSR: the earlier one writes in M
    assign stallD = stallE | (vD & (loaduse | st_ld | st_csr | mem_hold));

    // interrupt: injected by replacing the instruction moving into E
    reg  irq_q;
    wire inject = irq_q & ~io_valid & ~mem_hold;
    wire issue  = vD & ~stallD & ~kill_DE;

    wire prodE = vE & weE & ~lateE;
    wire prodM = vM & weM;
    wire nfAM  = rs1_used & prodE & (rdE == rs1D);
    wire nfAW  = rs1_used & prodM & (rdM == rs1D) & ~nfAM;
    wire nfBM  = rs2_used & ~use_imm & prodE & (rdE == rs2D);
    wire nfBW  = rs2_used & ~use_imm & prodM & (rdM == rs2D) & ~nfBM;

    // RAS: push on calls, pop on returns (at issue)
    wire d_link = (dJAL | dJALR) & (rdD == 5'd1 || rdD == 5'd5);
    wire d_ret  = dJALR & (rs1D == 5'd1 || rs1D == 5'd5) & (rdD == 5'd0);
    wire [31:0] pc4D = pcD + 32'd4;
    always @(posedge clk) begin
        if (rst) begin
            ras_sp <= 2'd0;
            ras[0] <= RESET_PC; ras[1] <= RESET_PC; ras[2] <= RESET_PC; ras[3] <= RESET_PC;
        end else if (vE & ~kill_DE & ~irqE) begin       // updated from E (registered)
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
                s_x    <= dJAL | dJALR | dMD | zCnt;
                s_add  <= ~(dJAL | dJALR | dMD) & (~(dOP | dOPI) | (dALU & f3D == 3'b000));
                s_sll  <= dALU & (f3D == 3'b001);
                s_slt  <= dALU & (f3D == 3'b010);
                s_sltu <= dALU & (f3D == 3'b011);
                s_xor  <= dALU & (f3D == 3'b100);
                s_sr   <= dALU & (f3D == 3'b101);
                s_or   <= dALU & (f3D == 3'b110);
                s_and  <= dALU & (f3D == 3'b111);
                binvE  <= zInv;
                s_ext  <= zExt;
                e_b    <= zSextB;
                e_h    <= zSextH;
                sh1E   <= zShadd & (f3D[2:1] == 2'b01);
                sh2E   <= zShadd & (f3D[2:1] == 2'b10);
                sh3E   <= zShadd & (f3D[2:1] == 2'b11);
                cntE   <= {zCtz | zCpop, zClz | zCpop};
                x_orcE <= zOrcB;
                x_revE <= zRev8;
                x_rotE <= zRot;
                x_rolE <= zRot & (f3D == 3'b001);
                x_mmE  <= zMinMx;
                ctrE   <= ctrD;
                hintE  <= irD[31];
                jtE    <= dJALR & (i12D == 12'd0) & ~((rs1D == 5'd1 || rs1D == 5'd5) & (rdD == 5'd0));
                subE   <= d_sub;
                sraE   <= f7D[5];
                if (inject | ~dLegal) begin
                    weE <= 1'b0; lateE <= 1'b0; ldE <= 1'b0; stE <= 1'b0; brE <= 1'b0;
                    jalrE <= 1'b0; linkE <= 1'b0; mdE <= 1'b0; csrE <= 1'b0;
                    mretE <= 1'b0; fenceE <= 1'b0; fenciE <= 1'b0;
                    xbE   <= 1'b0;
                    irqE  <= inject;
                    excE  <= ~inject;
                    causeE <= 4'd2;                     // illegal instruction
                end else begin
                    weE    <= d_we;
                    lateE  <= d_late;
                    ldE    <= dLD;
                    stE    <= dST;
                    brE    <= dBR;
                    jalrE  <= dJALR;
                    linkE  <= dJAL | dJALR;
                    mdE    <= dMD | zCnt;
                    csrE   <= dCSR;
                    mretE  <= dMRET;
                    fenceE <= dFENCE;
                    fenciE <= dFENCI;
                    xbE    <= zLate;
                    irqE   <= 1'b0;
                    excE   <= dECALL | dEBRK;
                    causeE <= dECALL ? 4'd11 : 4'd3;
                end
            end
        end else if (kill_DE)
            vE <= 1'b0;
    end

    // ========================================================================
    // E: execute
    // ========================================================================
    // Forwarding: separate copies per consumer (less load and routing)
    wire [31:0] a  /* synthesis syn_keep=1 */;      // ALU, CSR, mul/div
    wire [31:0] b  /* synthesis syn_keep=1 */;
    wire [31:0] ac /* synthesis syn_keep=1 */;      // branch compare / JALR
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
    wire        ltu   = ~sum33[32];                    // a - b with borrow
    wire        lt    = (a[31] ^ b[31]) ? a[31] : sum[31];
    wire [31:0] sll   = a << b[4:0];
    wire [31:0] srx   = $signed({sraE & a[31], a}) >>> b[4:0];

    // dedicated branch comparator
    wire [32:0] cmp33 = {1'b0, ac} - {1'b0, bc};
    wire        c_ltu = cmp33[32];
    wire        c_lt  = (ac[31] ^ bc[31]) ? ac[31] : cmp33[31];
    wire        c_eq  = (ac == bc);

    // Zbb andn / orn / xnor
    wire [31:0] bn = b ^ {32{binvE}};
    // Zbb sext.b / sext.h / zext.h
    wire [31:0] extv = {{16{e_b ? a[7] : (e_h & a[15])}}, e_b ? {8{a[7]}} : a[15:8], a[7:0]};

    // result: AND-OR with registered one-hot selects
    wire [31:0] md_res;
    wire [31:0] xres = linkE ? pc4E : md_res;
    wire [31:0] resE = ({32{s_add}}  & sum) |
                       ({32{s_sll}}  & sll) |
                       ({32{s_slt}}  & {31'd0, lt}) |
                       ({32{s_sltu}} & {31'd0, ltu}) |
                       ({32{s_xor}}  & (a ^ bn)) |
                       ({32{s_sr}}   & srx) |
                       ({32{s_or}}   & (a | bn)) |
                       ({32{s_and}}  & (a & bn)) |
                       ({32{s_ext}}  & extv) |
                       ({32{s_x}}    & xres);

    wire [31:0] agu = aa + immE;
    assign dc_addr  = agu;

    // muldiv
    wire md_start = vE & mdE & ~kill_DE;
    rv_muldiv u_md (
        .clk(clk), .rst(rst), .start(md_start), .kill(kill_DE), .op(f3E), .cnt(cntE),
        .a(a), .b(b), .done(md_done), .res(md_res)
    );

    // branches
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
    // only returns with imm = 0 are predicted: comparing rs1 with the target is enough
    wire        mis_jr = jalrE & (~predE | (tgtE[31:1] != ac[31:1]));
    wire        mispredict = liveE & (mis_br | mis_jr);
    // on a branch misprediction the target is the opposite of the predicted one
    wire [31:0] mis_pc = jalrE ? jtgt : (predE ? pc4E : tgtE);

    // predictor update: outcome registered in E, tables written the next cycle
    // (a branch replayed later counts twice: harmless)
    reg        bu_we, bu_dis, ju_we;
    reg [1:0]  bu_ctr;
    reg [7:0]  bu_idx;
    reg [4:0]  ju_idx;
    reg [22:0] ju_tgt;
    always @(posedge clk) begin
        bu_we  <= liveE & brE;
        bu_dis <= taken ^ hintE;
        bu_ctr <= ctrE;
        bu_idx <= pcE[9:2];
        ju_we  <= liveE & jtE;
        ju_idx <= pcE[6:2];
        ju_tgt <= {jtgt[30], jtgt[22:1]};
    end
    wire [1:0] bht_nv = bu_dis ? ((bu_ctr == 2'd3) ? 2'd3 : bu_ctr + 2'd1) :
                                 ((bu_ctr == 2'd0) ? 2'd0 : bu_ctr - 2'd1);
    always @(posedge clk) begin
        if (bu_we & ~rst) bht[bu_idx] <= bht_nv;
        if (ju_we & ~rst) jt[ju_idx] <= {ju_tgt, 1'b1};
    end

    // misalignment
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
            xbM    <= xbE;
            x_orcM <= x_orcE; x_revM <= x_revE; x_rotM <= x_rotE; x_mmM  <= x_mmE;
            sh1M   <= sh1E;   sh2M   <= sh2E;   sh3M   <= sh3E;
            // min/max: take a? (lt or ltu of the ALU, inverted for max)
            x_selaM <= (f3E[0] ? ltu : lt) ^ f3E[1];
            // rotations: amount to the right (rol = ror by -n)
            x_shM  <= x_rolE ? 5'd0 - b[4:0] : b[4:0];
            aM     <= a;
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
    // M: memory, CSR, exceptions
    // ========================================================================
    wire        liveM    = vM & ~flush_q;
    // the first uncacheable load reaching M after the replay is the one that requested the data
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
    // 64-bit counters in two halves with registered carry (the high half
    // updates one cycle later: read high-low-high as usual)
    reg [31:0] mcyc_l, mcyc_h, mins_l, mins_h;
    reg        mcyc_c, mins_c;
    wire [63:0] mcycle   = {mcyc_h, mcyc_l};
    wire [63:0] minstret = {mins_h, mins_l};
    assign dbg_instret = minstret;

    wire [31:0] mip = {20'd0, irq_ext, 3'd0, irq_timer, 3'd0, irq_soft, 3'd0};
    wire [31:0] mie = {20'd0, mie_meie, 3'd0, mie_mtie, 3'd0, mie_msie, 3'd0};
    wire        irq_now = mstatus_mie & ((irq_ext & mie_meie) | (irq_timer & mie_mtie) | (irq_soft & mie_msie));
    wire [3:0]  irq_cause = (irq_ext & mie_meie) ? 4'd11 : (irq_soft & mie_msie) ? 4'd3 : 4'd7;

    // The CSR is read in E (address = immE) and the value is passed registered to M.
    // Two consecutive CSR instructions are separated by a bubble (see st_csr).
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
    wire [31:0] csr_src = resM;                       // rs1 or zimm (passed through E)
    reg  [31:0] csr_w;
    always @(*) begin
        case (f3M[1:0])
        2'b01:   csr_w = csr_src;
        2'b10:   csr_w = csr_rq | csr_src;
        default: csr_w = csr_rq & ~csr_src;
        endcase
    end
    // CSRRS/CSRRC with rs1 = x0 / zimm = 0 do not write
    wire csr_wr_en = (f3M[1:0] == 2'b01) | (csr_src != 32'd0);

    // slow Zbb operations (operands registered: a whole cycle; one-hot selects)
    wire [63:0] rorw  = {aM, aM} >> x_shM;
    wire [31:0] shsum = (({32{sh1M}} & {aM[30:0], 1'b0}) | ({32{sh2M}} & {aM[29:0], 2'b0}) |
                         ({32{sh3M}} & {aM[28:0], 3'b0})) + sdM;     // 0 + sdM if not shNadd
    wire [31:0] xres_m = ({32{x_orcM}} & {{8{|aM[31:24]}}, {8{|aM[23:16]}}, {8{|aM[15:8]}}, {8{|aM[7:0]}}}) |
                         ({32{x_revM}} & {aM[7:0], aM[15:8], aM[23:16], aM[31:24]}) |
                         ({32{x_rotM}} & rorw[31:0]) |
                         ({32{x_mmM}}  & (x_selaM ? aM : sdM)) |
                         ({32{sh1M | sh2M | sh3M}} & shsum);

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

    // redirect
    always @(posedge clk) begin
        if (rst) begin
            redirect_q <= 1'b0;
            flush_q    <= 1'b0;
        end else begin
            flush_q    <= flush_n;
            redirect_q <= flush_n | mispredict;
            flush_pc_q <= flush_pc_n;   // early select (does not depend on hits)
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

    // M -> W (the late results other than loads are merged first, off the load path)
    // (xres_m is 0 unless a slow operation is in M)
    wire [31:0] resMx = csrM ? csr_rq : (xres_m | ({32{~xbM}} & resM));
    always @(posedge clk) begin
        if (rst) begin
            vW <= 1'b0; weW <= 1'b0;
        end else begin
            vW   <= liveM & ~replay & ~trap;
            weW  <= weM & liveM & ~replay & ~trap;
            rdW  <= rdM;
            resW <= ldM ? ldata : resMx;
        end
    end

endmodule
`default_nettype wire
