// ============================================================================
// icache.v - Caché de instrucciones, mapeo directo, líneas de 32 bytes
//   Datos: (2^IDXW) x 8 palabras en BSRAM (SDP), etiquetas en otra BSRAM.
//   Lectura: la dirección se captura cuando en = 1; rdata/hit corresponden a
//   la última dirección capturada (se mantienen con en = 0).
//   Escritura (unidad de memoria): palabras de relleno y etiquetas.
//   Etiqueta = {addr[30], addr[22:13]} (ROM / SDRAM de 8 MB) + bit de validez.
// ============================================================================
`default_nettype none
module icache #(
    parameter IDXW = 8                  // 256 líneas = 8 KB
)(
    input  wire        clk,
    input  wire        en,
    input  wire [31:0] addr,
    output wire [31:0] rdata,
    output wire        hit,
    // escritura
    input  wire        dwe,
    input  wire [IDXW+2:0] dwidx,       // índice de palabra
    input  wire [31:0] dwdata,
    input  wire        twe,
    input  wire [IDXW-1:0] twidx,
    input  wire [11:0] twdata           // {valid, tag[10:0]}
);
    localparam AW = IDXW + 3;

    reg [31:0] dmem [0:(1<<AW)-1];
    reg [11:0] tmem [0:(1<<IDXW)-1];
    reg [31:0] dq;
    reg [11:0] tq;
    reg [11:0] ra_tag;                  // {1, tag} de la dirección capturada

    integer i;
    initial for (i = 0; i < (1<<IDXW); i = i + 1) tmem[i] = 12'd0;

    always @(posedge clk) begin
        if (dwe) dmem[dwidx] <= dwdata;
        if (en)  dq <= dmem[addr[AW+1:2]];
    end
    always @(posedge clk) begin
        if (twe) tmem[twidx] <= twdata;
        if (en)  tq <= tmem[addr[IDXW+4:5]];
    end
    always @(posedge clk)
        if (en) ra_tag <= {1'b1, addr[30], addr[22:13]};

    assign rdata = dq;
    assign hit   = (tq == ra_tag);
endmodule
`default_nettype wire
