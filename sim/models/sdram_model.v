// ============================================================================
// sdram_model.v - Modelo de comportamiento de una SDR SDRAM 2M x 32 (4 bancos)
// para simulación: BL = 1, CL programado por MRS, máscaras DQM, y
// comprobación de tiempos (tRCD, tRP, tRAS, tWR, tRC, tRFC, refresco).
// Salida de lectura con tAC / tOH reales para probar la ventana de captura.
// ============================================================================
`timescale 1ns/1ps
module sdram_model #(
    parameter real TAC  = 5.4,          // reloj -> dato válido (ns)
    parameter real TOH  = 2.5,          // dato válido tras el siguiente flanco (ns)
    parameter T_RCD = 2, T_RP = 2, T_RAS = 5, T_WR = 2, T_RFC = 7, T_RC = 7,
    parameter REF_MAX_CYC = 1600,       // máximo entre REFRESH (relajado)
    parameter INIT_FILE = ""
)(
    input  wire        clk,
    input  wire        cke,
    input  wire        cs_n, ras_n, cas_n, we_n,
    input  wire [1:0]  ba,
    input  wire [10:0] a,
    input  wire [3:0]  dqm,
    inout  wire [31:0] dq
);
    reg [31:0] mem [0:2097151];
    reg [31:0] dq_out;
    reg        dq_oe;
    assign dq = dq_oe ? dq_out : 32'bz;
    // bus sin conducir: pull-down débil (en la placa sería basura, nunca X)
    assign (weak0, weak1) dq = 32'h0000_0000;

    integer cyc = 0;
    integer cl = 2;
    reg     row_open [0:3];
    reg [10:0] row [0:3];
    integer t_act [0:3], t_pre [0:3], t_wr [0:3];
    integer t_ref = 0, t_last_ref = 0;
    integer errors = 0;
    reg     inited = 0;

    // tubería de lectura: dato y válido por ciclo futuro
    reg [31:0] rd_data [0:7];
    reg        rd_v    [0:7];
    integer i;

    initial begin
        for (i = 0; i < 4; i = i + 1) begin
            row_open[i] = 0; t_act[i] = -100; t_pre[i] = -100; t_wr[i] = -100;
        end
        for (i = 0; i < 8; i = i + 1) rd_v[i] = 0;
        dq_oe = 0;
        for (i = 0; i < 2097152; i = i + 1) mem[i] = 32'd0;
        if (INIT_FILE != "") $readmemh(INIT_FILE, mem);
    end

    wire [3:0] cmd = {cs_n, ras_n, cas_n, we_n};
    wire [20:0] waddr = {row[ba], ba, a[7:0]};

    task err(input [8*48-1:0] msg);
        begin
            errors = errors + 1;
            if (errors < 20) $display("[%0t] SDRAM ERROR: %0s (ciclo %0d)", $time, msg, cyc);
        end
    endtask

    always @(posedge clk) begin
        cyc = cyc + 1;
        // salida de lectura programada para este flanco
        for (i = 0; i < 7; i = i + 1) begin
            rd_data[i] = rd_data[i+1];
            rd_v[i]    = rd_v[i+1];
        end
        rd_v[7] = 0;
        if (rd_v[0]) begin
            dq_oe  <= #(TOH) 1'b1;
            dq_out <= #(TOH) 32'hDEAD_BEEF;              // dato en transición (basura)
            dq_out <= #(TAC) rd_data[0];
        end else begin
            dq_oe  <= #(TOH) 1'b0;
        end

        if (cke && inited && (cyc - t_last_ref) > REF_MAX_CYC) begin
            err("refresco atrasado");
            t_last_ref = cyc;
        end

        if (cke) case (cmd)
        4'b0011: begin                                  // ACTIVE
            if (row_open[ba])                     err("ACT con banco abierto");
            if (cyc - t_pre[ba] < T_RP)           err("tRP");
            if (cyc - t_act[ba] < T_RC)           err("tRC");
            if (cyc - t_ref < T_RFC)              err("tRFC (ACT)");
            row_open[ba] = 1; row[ba] = a; t_act[ba] = cyc;
        end
        4'b0101: begin                                  // READ
            if (!row_open[ba])                    err("READ con banco cerrado");
            if (cyc - t_act[ba] < T_RCD)          err("tRCD (READ)");
            if (a[10])                            err("auto-precharge no esperado");
            rd_data[cl-1] = mem[waddr];
            rd_v[cl-1]    = 1;
        end
        4'b0100: begin                                  // WRITE
            if (!row_open[ba])                    err("WRITE con banco cerrado");
            if (cyc - t_act[ba] < T_RCD)          err("tRCD (WRITE)");
            if (!dqm[0]) mem[waddr][7:0]   = dq[7:0];
            if (!dqm[1]) mem[waddr][15:8]  = dq[15:8];
            if (!dqm[2]) mem[waddr][23:16] = dq[23:16];
            if (!dqm[3]) mem[waddr][31:24] = dq[31:24];
            t_wr[ba] = cyc;
        end
        4'b0010: begin                                  // PRECHARGE
            for (i = 0; i < 4; i = i + 1)
                if (a[10] || ba == i) begin
                    if (row_open[i] && cyc - t_act[i] < T_RAS) err("tRAS");
                    if (row_open[i] && cyc - t_wr[i] < T_WR)   err("tWR");
                    row_open[i] = 0; t_pre[i] = cyc;
                end
        end
        4'b0001: begin                                  // AUTO REFRESH
            for (i = 0; i < 4; i = i + 1) begin
                if (row_open[i])                  err("REF con banco abierto");
                if (cyc - t_pre[i] < T_RP)        err("tRP (REF)");
            end
            if (cyc - t_ref < T_RFC)              err("tRFC (REF)");
            t_ref = cyc; t_last_ref = cyc;
        end
        4'b0000: begin                                  // MODE REGISTER
            cl = a[6:4];
            if (a[2:0] != 3'b000)                 err("BL distinto de 1");
            inited = 1;
            t_last_ref = cyc;
        end
        default: ;
        endcase
    end
endmodule
