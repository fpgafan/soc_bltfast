// ============================================================================
// dcache.v - Caché de datos, mapeo directo, líneas de 32 bytes, escritura
// directa sin reserva (write-through, no-allocate).
//   Lectura: dirección desde E (capturada cada ciclo), dato/acierto en M.
//   Escritura de datos: store con aciertos (máscara de bytes) o relleno.
//   4 BSRAM de 8 bits (una por byte) + 1 BSRAM de etiquetas.
// ============================================================================
`default_nettype none
module dcache #(
    parameter IDXW = 8                  // 256 líneas = 8 KB
)(
    input  wire        clk,
    input  wire [31:0] raddr,
    output wire [31:0] rdata,
    output wire        hit,
    // escritura de datos (store o relleno)
    input  wire [3:0]  wbe,
    input  wire [IDXW+2:0] widx,
    input  wire [31:0] wdata,
    // etiquetas
    input  wire        twe,
    input  wire [IDXW-1:0] twidx,
    input  wire [11:0] twdata
);
    localparam AW = IDXW + 3;

    reg [7:0]  m0 [0:(1<<AW)-1];
    reg [7:0]  m1 [0:(1<<AW)-1];
    reg [7:0]  m2 [0:(1<<AW)-1];
    reg [7:0]  m3 [0:(1<<AW)-1];
    reg [11:0] tmem [0:(1<<IDXW)-1];
    reg [7:0]  q0, q1, q2, q3;
    reg [11:0] tq, ra_tag;

    integer i;
    initial for (i = 0; i < (1<<IDXW); i = i + 1) tmem[i] = 12'd0;

    wire [AW-1:0] ri = raddr[AW+1:2];
    always @(posedge clk) begin if (wbe[0]) m0[widx] <= wdata[7:0];   q0 <= m0[ri]; end
    always @(posedge clk) begin if (wbe[1]) m1[widx] <= wdata[15:8];  q1 <= m1[ri]; end
    always @(posedge clk) begin if (wbe[2]) m2[widx] <= wdata[23:16]; q2 <= m2[ri]; end
    always @(posedge clk) begin if (wbe[3]) m3[widx] <= wdata[31:24]; q3 <= m3[ri]; end
    always @(posedge clk) begin
        if (twe) tmem[twidx] <= twdata;
        tq <= tmem[raddr[IDXW+4:5]];
    end
    always @(posedge clk) ra_tag <= {1'b1, raddr[30], raddr[22:13]};

    assign rdata = {q3, q2, q1, q0};
    assign hit   = (tq == ra_tag);
endmodule
`default_nettype wire
