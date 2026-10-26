// ============================================================================
// icache.v - Instruction cache, direct-mapped, 32-byte lines
//   Data: (2^IDXW) x 8 words in BSRAM (SDP), tags in another BSRAM.
//   Read: the address is latched when en = 1; rdata/hit correspond to
//   the last latched address (held while en = 0).
//   Write (memory unit): refill words and tags.
//   Tag = {addr[30], addr[22:IDXW+5]} (ROM / 8 MB SDRAM) + valid bit.
// ============================================================================
`default_nettype none
module icache #(
    parameter IDXW = 9,                 // 512 lines = 16 KB
    parameter TW   = 20 - IDXW          // {valid, addr[30], addr[22:IDXW+5]}
)(
    input  wire        clk,
    input  wire        en,
    input  wire [31:0] addr,
    output wire [31:0] rdata,
    output wire        hit,
    // write
    input  wire        dwe,
    input  wire [IDXW+2:0] dwidx,       // word index
    input  wire [31:0] dwdata,
    input  wire        twe,
    input  wire [IDXW-1:0] twidx,
    input  wire [TW-1:0] twdata         // {valid, tag}
);
    localparam AW = IDXW + 3;

    reg [31:0] dmem [0:(1<<AW)-1];
    reg [TW-1:0] tmem [0:(1<<IDXW)-1];
    reg [31:0] dq;
    reg [TW-1:0] tq;
    reg [TW-1:0] ra_tag;                // {1, tag} of the latched address

    integer i;
    initial for (i = 0; i < (1<<IDXW); i = i + 1) tmem[i] = {TW{1'b0}};

    always @(posedge clk) begin
        if (dwe) dmem[dwidx] <= dwdata;
        if (en)  dq <= dmem[addr[AW+1:2]];
    end
    always @(posedge clk) begin
        if (twe) tmem[twidx] <= twdata;
        if (en)  tq <= tmem[addr[IDXW+4:5]];
    end
    always @(posedge clk)
        if (en) ra_tag <= {1'b1, addr[30], addr[22:IDXW+5]};

    assign rdata = dq;
    assign hit   = (tq == ra_tag);
endmodule
`default_nettype wire
