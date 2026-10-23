// ============================================================================
// rv_muldiv.v - Extensión M
//   MUL/MULH/MULHSU/MULHU : 4 ciclos en E (operandos -> 4 productos parciales
//                           17x17 en DSP -> suma -> resultado), segmentado
//   DIV/DIVU/REM/REMU     : radix-2 con restauración, salta los bytes a cero
//                           iniciales del dividendo (de 12 a 38 ciclos)
// 'start' se mantiene mientras la instrucción está en E; se acepta en IDLE.
// 'done' dura un ciclo y 'res' es válido en ese ciclo.
// ============================================================================
`default_nettype none
module rv_muldiv (
    input  wire        clk,
    input  wire        rst,
    input  wire        start,
    input  wire        kill,
    input  wire [2:0]  op,
    input  wire [31:0] a,
    input  wire [31:0] b,
    output wire        done,
    output wire [31:0] res
);
    localparam S_IDLE = 4'd0, S_M1 = 4'd1, S_M2 = 4'd2, S_M3 = 4'd3,
               S_DIV = 4'd4, S_DFIN = 4'd5, S_DONE = 4'd6, S_DSKIP = 4'd7, S_DABS = 4'd8;
    reg [3:0] st;

    // ---------------------------------------------------------------- multiplicación
    reg               mhi;                        // devolver la parte alta
    reg signed [16:0] ah, bh, al, bl;             // al/bl con bit 16 = 0
    reg signed [33:0] p_hh, p_hl, p_lh, p_ll;
    reg        [65:0] prod;

    wire a_sgn = (op[1:0] == 2'b01) | (op[1:0] == 2'b10);   // MULH, MULHSU
    wire b_sgn = (op[1:0] == 2'b01);                        // MULH
    wire [32:0] a33 = {a_sgn & a[31], a};
    wire [32:0] b33 = {b_sgn & b[31], b};

    // ---------------------------------------------------------------- división
    reg  [31:0] dq, dr, dd;            // cociente / resto parcial / divisor (abs)
    reg  [31:0] dn;                    // dividendo desplazado
    reg  [5:0]  dcnt;
    reg         neg_q, neg_r, want_rem, div0;
    reg  [31:0] a_orig;
    reg  [31:0] dres;

    wire div_signed = ~op[0];
    reg         dsg;                    // división con signo
    reg  [31:0] da_raw, db_raw;

    wire [32:0] trial = {dr[31:0], dn[31]} - {1'b0, dd};

    always @(posedge clk) begin
        if (rst || kill) begin
            st <= S_IDLE;
        end else begin
            case (st)
            S_IDLE: if (start) begin
                if (!op[2]) begin
                    mhi <= (op[1:0] != 2'b00);
                    ah  <= a33[32:16];  al <= {1'b0, a33[15:0]};
                    bh  <= b33[32:16];  bl <= {1'b0, b33[15:0]};
                    st  <= S_M1;
                end else begin
                    want_rem <= op[1];
                    neg_q    <= div_signed & (a[31] ^ b[31]);
                    neg_r    <= div_signed & a[31];
                    div0     <= (b == 32'd0);
                    a_orig   <= a;
                    dsg      <= div_signed;
                    da_raw   <= a;
                    db_raw   <= b;
                    dcnt     <= 6'd32;
                    dq       <= 32'd0;
                    dr       <= 32'd0;
                    st       <= S_DABS;
                end
            end
            S_DABS: begin                     // valores absolutos
                dn <= (dsg & da_raw[31]) ? -da_raw : da_raw;
                dd <= (dsg & db_raw[31]) ? -db_raw : db_raw;
                st <= S_DSKIP;
            end
            S_DSKIP: begin                    // salta bytes iniciales a cero
                if (dn[31:24] == 8'd0 && dcnt > 6'd8) begin
                    dn   <= {dn[23:0], 8'd0};
                    dcnt <= dcnt - 6'd8;
                end else
                    st <= S_DIV;
            end
            S_M1: begin
                p_hh <= ah * bh;
                p_hl <= ah * bl;
                p_lh <= al * bh;
                p_ll <= al * bl;
                st   <= S_M2;
            end
            S_M2: begin
                prod <= ({{32{p_hh[33]}}, p_hh} << 32)
                      + ({{32{p_hl[33]}}, p_hl} << 16)
                      + ({{32{p_lh[33]}}, p_lh} << 16)
                      + {{32{p_ll[33]}}, p_ll};
                st   <= S_M3;
            end
            S_M3: st <= S_IDLE;
            S_DIV: begin
                if (dcnt == 6'd0)
                    st <= S_DFIN;
                else begin
                    dcnt <= dcnt - 6'd1;
                    dn   <= {dn[30:0], 1'b0};
                    if (!trial[32]) begin
                        dr <= trial[31:0];
                        dq <= {dq[30:0], 1'b1};
                    end else begin
                        dr <= {dr[30:0], dn[31]};
                        dq <= {dq[30:0], 1'b0};
                    end
                end
            end
            S_DFIN: begin
                if (div0)
                    dres <= want_rem ? a_orig : 32'hFFFF_FFFF;
                else if (want_rem)
                    dres <= neg_r ? -dr : dr;
                else
                    dres <= neg_q ? -dq : dq;
                st <= S_DONE;
            end
            S_DONE: st <= S_IDLE;
            default: st <= S_IDLE;
            endcase
        end
    end

    assign done = (st == S_M3) | (st == S_DONE);
    assign res  = (st == S_M3) ? (mhi ? prod[63:32] : prod[31:0]) : dres;

endmodule
`default_nettype wire
