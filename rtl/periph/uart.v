// ============================================================================
// uart.v - 8N1 UART with FIFOs (TX 16, RX 64) and programmable divider
//   +0x00 DATA   W: queues a byte to send
//                R: [7:0] received byte (consumes it), [8] = valid
//   +0x04 STAT   R: [0] TX full, [1] TX empty and idle, [2] RX has data,
//                   [3] RX overflow (cleared when STAT is read)
//   +0x08 DIV    R/W: clock cycles per bit (default CLK/115200)
//   +0x0C IE     R/W: [0] interrupt on RX data
//   Remote reset: the sequence 'R','V','R','S','T','!' received back to back
//   produces a sw_reset pulse (used by the PC loader).
// ============================================================================
`default_nettype none
module uart #(
    parameter CLK_HZ = 100_000_000,
    parameter BAUD   = 115200
)(
    input  wire        clk,
    input  wire        rst,
    input  wire        sel,
    input  wire        we,
    input  wire [3:0]  a,
    input  wire [31:0] wd,
    output reg  [31:0] rd,
    output wire        irq,
    output reg         sw_reset,
    input  wire        rxd,
    output reg         txd
);
    localparam [15:0] DIV0 = CLK_HZ / BAUD;
    reg [15:0] div;
    reg        ie;

    // ---------------------------------------------------------------- TX
    reg [7:0] txf [0:15];
    reg [3:0] tx_wp, tx_rp;
    reg [4:0] tx_n;
    reg [9:0] tx_sh;
    reg [3:0] tx_bits;
    reg [15:0] tx_cnt;
    wire tx_full  = tx_n == 5'd16;
    wire tx_busy  = tx_bits != 4'd0;

    // ---------------------------------------------------------------- RX
    reg [2:0] rx_s;
    always @(posedge clk) rx_s <= {rx_s[1:0], rxd};
    wire rx = rx_s[2];
    reg [7:0] rxf [0:63];
    reg [5:0] rx_wp, rx_rp;
    reg [6:0] rx_n;
    reg       rx_ovf;
    reg [15:0] rx_cnt;
    reg [3:0] rx_bits;
    reg [7:0] rx_sh;
    reg       rx_act;
    reg [2:0] magic;                 // position in the reset sequence

    wire rd_data = sel & ~we & (a[3:2] == 2'd0);
    wire wr_data = sel &  we & (a[3:2] == 2'd0);
    wire pop     = rd_data & (rx_n != 7'd0);

    assign irq = ie & (rx_n != 7'd0);

    reg       rx_push;
    reg [7:0] rx_byte;

    always @(posedge clk) begin
        sw_reset <= 1'b0;
        rx_push  <= 1'b0;
        if (rst) begin
            div <= DIV0; ie <= 1'b0;
            tx_wp <= 0; tx_rp <= 0; tx_n <= 0; tx_bits <= 0; txd <= 1'b1;
            rx_wp <= 0; rx_rp <= 0; rx_n <= 0; rx_ovf <= 0; rx_act <= 0;
            magic <= 0;
        end else begin
            // registers
            if (sel & we) begin
                case (a[3:2])
                2'd2: div <= wd[15:0];
                2'd3: ie  <= wd[0];
                default: ;
                endcase
            end
            if (sel & ~we & (a[3:2] == 2'd1)) rx_ovf <= 1'b0;

            // TX
            if (wr_data && !tx_full) begin
                txf[tx_wp] <= wd[7:0];
                tx_wp <= tx_wp + 4'd1;
            end
            if (!tx_busy) begin
                if (tx_n != 5'd0) begin
                    txd     <= 1'b0;                     // start bit
                    tx_sh   <= {2'b11, txf[tx_rp]};      // data + stop + idle
                    tx_rp   <= tx_rp + 4'd1;
                    tx_bits <= 4'd10;
                    tx_cnt  <= div;
                end
            end else if (tx_cnt == 16'd1) begin
                txd     <= tx_sh[0];
                tx_sh   <= {1'b1, tx_sh[9:1]};
                tx_bits <= tx_bits - 4'd1;
                tx_cnt  <= div;
            end else
                tx_cnt <= tx_cnt - 16'd1;
            tx_n <= tx_n + ((wr_data && !tx_full) ? 5'd1 : 5'd0)
                         - ((!tx_busy && tx_n != 5'd0) ? 5'd1 : 5'd0);

            // RX
            if (!rx_act) begin
                if (!rx) begin
                    rx_act  <= 1'b1;
                    rx_cnt  <= {1'b0, div[15:1]};    // half bit
                    rx_bits <= 4'd0;
                end
            end else if (rx_cnt != 16'd0)
                rx_cnt <= rx_cnt - 16'd1;
            else begin
                rx_cnt <= div - 16'd1;
                if (rx_bits == 4'd0) begin
                    if (rx) rx_act <= 1'b0;          // false start
                    rx_bits <= 4'd1;
                end else if (rx_bits != 4'd9) begin
                    rx_sh   <= {rx, rx_sh[7:1]};
                    rx_bits <= rx_bits + 4'd1;
                end else begin
                    rx_act <= 1'b0;
                    if (rx) begin                    // valid stop
                        rx_push <= 1'b1;
                        rx_byte <= rx_sh;
                    end
                end
            end
            if (rx_push) begin
                if (rx_n == 7'd64) rx_ovf <= 1'b1;
                else begin
                    rxf[rx_wp] <= rx_byte;
                    rx_wp <= rx_wp + 6'd1;
                end
                // reset sequence "RVRST!"
                case (magic)
                3'd0: magic <= (rx_byte == "R") ? 3'd1 : 3'd0;
                3'd1: magic <= (rx_byte == "V") ? 3'd2 : (rx_byte == "R") ? 3'd1 : 3'd0;
                3'd2: magic <= (rx_byte == "R") ? 3'd3 : 3'd0;
                3'd3: magic <= (rx_byte == "S") ? 3'd4 : (rx_byte == "V") ? 3'd2 : 3'd0;
                3'd4: magic <= (rx_byte == "T") ? 3'd5 : (rx_byte == "R") ? 3'd1 : 3'd0;
                3'd5: begin
                    magic <= 3'd0;
                    if (rx_byte == "!") sw_reset <= 1'b1;
                end
                default: magic <= 3'd0;
                endcase
            end
            if (pop) rx_rp <= rx_rp + 6'd1;
            rx_n <= rx_n + ((rx_push && rx_n != 7'd64) ? 7'd1 : 7'd0) - (pop ? 7'd1 : 7'd0);

            // read
            case (a[3:2])
            2'd0: rd <= {23'd0, rx_n != 7'd0, rxf[rx_rp]};
            2'd1: rd <= {28'd0, rx_ovf, rx_n != 7'd0, ~tx_busy & (tx_n == 5'd0), tx_full};
            2'd2: rd <= {16'd0, div};
            default: rd <= {31'd0, ie};
            endcase
        end
    end
endmodule
`default_nettype wire
