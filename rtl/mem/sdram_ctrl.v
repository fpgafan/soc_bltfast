// ============================================================================
// sdram_ctrl.v - Controlador de la SDRAM embebida del GW2AR-18 (2M x 32)
//
//   4 bancos x 2048 filas x 256 columnas, BL = 1 programado; cada transacción
//   es ACTIVE + 1..16 READ/WRITE consecutivos (misma fila) + PRECHARGE.
//   Mapeo de la dirección de palabra a[22:2]: columna a[9:2], banco a[11:10],
//   fila a[22:12] (una ráfaga no debe cruzar un límite de 1 KB).
//
//   Maestros (prioridad fija 0 > 1, y turno rotatorio entre 2 y 3):
//     0 = vídeo, 1 = sonido, 2 = CPU, 3 = motor 2D
//   Protocolo por maestro:
//     req/we/addr/len (len = palabras - 1) se mantienen hasta ack (1 ciclo).
//     Escritura: el controlador toma wdata/wmask del maestro en curso y da
//       wnext (1 ciclo) por cada palabra; el maestro presenta la siguiente
//       palabra en el ciclo siguiente.
//     Lectura: rvalid[i] + rdata, en orden, una por palabra.
//
//   rd_lat: ciclos entre el registro de la orden READ y la captura del dato
//   (programable para calibrar en la placa junto con la fase del reloj).
//   Todas las salidas hacia la SDRAM están registradas (IOB).
// ============================================================================
`default_nettype none
module sdram_ctrl #(
    parameter CLK_MHZ   = 100,
    parameter CL        = 2,
    parameter T_RCD     = 2,
    parameter T_RP      = 2,
    parameter T_RAS     = 5,
    parameter T_WR      = 2,
    parameter T_RFC     = 7,
    parameter T_MRD     = 2,
    parameter INIT_US   = 200,
    parameter REF_US    = 7             // ~7.8 us por fila
)(
    input  wire          clk,
    input  wire          rst,
    input  wire [2:0]    rd_lat,
    output reg           ready,         // inicialización terminada

    input  wire [3:0]    req,
    input  wire [3:0]    we,
    input  wire [4*21-1:0] addr,
    input  wire [4*4-1:0]  len,
    output reg  [3:0]    ack,
    input  wire [4*32-1:0] wdata,
    input  wire [4*4-1:0]  wmask,
    output wire [3:0]    wnext,
    output reg  [31:0]   rdata,
    output reg  [3:0]    rvalid,

    // SDRAM
    output wire          sd_cke,
    output wire          sd_cs_n,
    output wire          sd_ras_n,
    output wire          sd_cas_n,
    output wire          sd_we_n,
    output wire [1:0]    sd_ba,
    output wire [10:0]   sd_a,
    output wire [3:0]    sd_dqm,
    inout  wire [31:0]   sd_dq
);
    // ------------------------------------------------------------------ órdenes
    localparam [3:0] C_NOP = 4'b0111, C_ACT = 4'b0011, C_RD = 4'b0101, C_WR = 4'b0100,
                     C_PRE = 4'b0010, C_REF = 4'b0001, C_MRS = 4'b0000;

    (* syn_useioff = 1 *) reg [3:0]  cmd_q;
    (* syn_useioff = 1 *) reg [1:0]  ba_q;
    (* syn_useioff = 1 *) reg [10:0] a_q;
    (* syn_useioff = 1 *) reg [3:0]  dqm_q;
    (* syn_useioff = 1 *) reg [31:0] dqo_q;
    (* syn_useioff = 1 *) reg        dqoe_q;
    (* syn_useioff = 1 *) reg [31:0] dqi_q;
    reg cke_q;

    assign sd_cke   = cke_q;
    assign {sd_cs_n, sd_ras_n, sd_cas_n, sd_we_n} = cmd_q;
    assign sd_ba    = ba_q;
    assign sd_a     = a_q;
    assign sd_dqm   = dqm_q;
    assign sd_dq    = dqoe_q ? dqo_q : 32'bz;

    always @(posedge clk) dqi_q <= sd_dq;

    // ------------------------------------------------------------------ estado
    localparam INIT_CYC = INIT_US * CLK_MHZ;
    localparam REF_CYC  = REF_US * CLK_MHZ;

    localparam S_INIT = 3'd0, S_IDLE = 3'd1, S_ACTW = 3'd2, S_RW = 3'd3,
               S_PREW = 3'd4, S_WAIT = 3'd5;
    reg [2:0]  st;
    reg [15:0] icnt;                    // contador de inicialización
    reg [3:0]  istep;
    reg [3:0]  wcnt;                    // espera genérica
    reg [15:0] rcnt;                    // intervalo de refresco
    reg        ref_pend;

    reg [1:0]  cur;                     // maestro en curso
    reg        cur_we;
    reg [1:0]  cur_ba;
    reg [10:0] cur_row;
    reg [7:0]  cur_col;
    reg [3:0]  cur_left;                // palabras que faltan - 1
    reg [3:0]  ras_cnt;                 // ciclos desde ACTIVE
    reg [3:0]  rp_cnt;                  // ciclos que faltan para otro ACTIVE/REF
    reg [3:0]  wr_cnt;                  // ciclos desde el último WRITE
    reg        rr;                      // turno 2/3

    // tubería de lectura: {válido, maestro} por ciclo
    reg [2:0]  rpipe [0:7];
    integer    k;

    // selección de maestro
    reg        g_any;
    reg [1:0]  g_id;
    always @(*) begin
        g_any = |req;
        if (req[0])                 g_id = 2'd0;
        else if (req[1])            g_id = 2'd1;
        else if (req[2] & req[3])   g_id = rr ? 2'd3 : 2'd2;
        else if (req[2])            g_id = 2'd2;
        else                        g_id = 2'd3;
    end
    wire [20:0] g_addr = addr[g_id*21 +: 21];

    wire [31:0] cur_wdata = wdata[cur*32 +: 32];
    // wnext es combinacional: el maestro pasa a la palabra siguiente en este flanco
    assign wnext = (st == S_RW && cur_we) ? (4'b0001 << cur) : 4'b0000;
    wire [3:0]  cur_wmask = wmask[cur*4 +: 4];

    always @(posedge clk) begin
        ack    <= 4'd0;
        cmd_q  <= C_NOP;
        dqoe_q <= 1'b0;
        dqm_q  <= 4'b0000;

        // tubería de lectura (siempre corre)
        for (k = 7; k > 0; k = k - 1) rpipe[k] <= rpipe[k-1];
        rpipe[0] <= 3'b000;
        rvalid <= 4'd0;
        if (rpipe[rd_lat][2]) begin
            rvalid[rpipe[rd_lat][1:0]] <= 1'b1;
        end
        rdata <= dqi_q;

        if (rp_cnt != 4'd0)  rp_cnt  <= rp_cnt - 4'd1;
        if (ras_cnt != 4'd15) ras_cnt <= ras_cnt + 4'd1;
        if (wr_cnt != 4'd15)  wr_cnt  <= wr_cnt + 4'd1;

        if (rcnt == REF_CYC[15:0] - 16'd1) begin
            rcnt     <= 16'd0;
            ref_pend <= 1'b1;
        end else
            rcnt <= rcnt + 16'd1;

        if (rst) begin
            st       <= S_INIT;
            icnt     <= 16'd0;
            istep    <= 4'd0;
            ready    <= 1'b0;
            cke_q    <= 1'b0;
            ref_pend <= 1'b0;
            rcnt     <= 16'd0;
            rp_cnt   <= 4'd0;
            rr       <= 1'b0;
            for (k = 0; k < 8; k = k + 1) rpipe[k] <= 3'b000;
        end else begin
            case (st)
            // ---------------------------------------------------------- init
            S_INIT: begin
                cke_q <= 1'b1;
                if (icnt != INIT_CYC[15:0])
                    icnt <= icnt + 16'd1;
                else if (rp_cnt == 4'd0) begin
                    case (istep)
                    4'd0: begin                       // PRECHARGE ALL
                        cmd_q <= C_PRE; a_q <= 11'h400;
                        rp_cnt <= T_RP[3:0];
                        istep <= 4'd1;
                    end
                    4'd1, 4'd2, 4'd3, 4'd4, 4'd5, 4'd6, 4'd7, 4'd8: begin   // 8 x REFRESH
                        cmd_q <= C_REF;
                        rp_cnt <= T_RFC[3:0];
                        istep <= istep + 4'd1;
                    end
                    4'd9: begin                       // MODE REGISTER: BL=1, secuencial, CL
                        cmd_q <= C_MRS; ba_q <= 2'b00;
                        a_q <= {4'b0000, CL[2:0], 4'b0000};
                        rp_cnt <= T_MRD[3:0];
                        istep <= 4'd10;
                    end
                    default: begin
                        ready <= 1'b1;
                        ref_pend <= 1'b0;
                        st <= S_IDLE;
                    end
                    endcase
                end
            end
            // ---------------------------------------------------------- reposo
            S_IDLE: begin
                if (rp_cnt == 4'd0) begin
                    if (ref_pend) begin
                        cmd_q    <= C_REF;
                        rp_cnt   <= T_RFC[3:0];
                        ref_pend <= 1'b0;
                    end else if (g_any) begin
                        cur      <= g_id;
                        cur_we   <= we[g_id];
                        cur_ba   <= g_addr[9:8];
                        cur_row  <= g_addr[20:10];
                        cur_col  <= g_addr[7:0];
                        cur_left <= len[g_id*4 +: 4];
                        ack[g_id] <= 1'b1;
                        if (g_id[1]) rr <= ~g_id[0];
                        cmd_q    <= C_ACT;
                        ba_q     <= g_addr[9:8];
                        a_q      <= g_addr[20:10];
                        ras_cnt  <= 4'd1;
                        wcnt     <= T_RCD[3:0] - 4'd1;
                        st       <= (T_RCD > 1) ? S_ACTW : S_RW;
                    end
                end
            end
            S_ACTW: begin
                if (wcnt == 4'd1) st <= S_RW;
                wcnt <= wcnt - 4'd1;
            end
            // ---------------------------------------------------------- lectura / escritura
            S_RW: begin
                ba_q <= cur_ba;
                a_q  <= {3'b000, cur_col};
                if (cur_we) begin
                    cmd_q  <= C_WR;
                    dqo_q  <= cur_wdata;
                    dqm_q  <= ~cur_wmask;
                    dqoe_q <= 1'b1;
                    wr_cnt <= 4'd1;
                end else begin
                    cmd_q    <= C_RD;
                    rpipe[0] <= {1'b1, cur};
                end
                cur_col  <= cur_col + 8'd1;
                cur_left <= cur_left - 4'd1;
                if (cur_left == 4'd0) st <= S_PREW;
            end
            S_PREW: begin
                // PRECHARGE cuando se cumplen tRAS y tWR (escritura)
                if (ras_cnt >= T_RAS[3:0] && (!cur_we || wr_cnt >= T_WR[3:0])) begin
                    cmd_q  <= C_PRE;
                    ba_q   <= cur_ba;
                    a_q    <= 11'h000;
                    rp_cnt <= T_RP[3:0] - 4'd1;
                    st     <= S_IDLE;
                end
            end
            default: st <= S_IDLE;
            endcase
        end
    end
endmodule
`default_nettype wire
