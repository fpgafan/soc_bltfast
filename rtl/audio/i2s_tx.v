// ============================================================================
// i2s_tx.v - 16-bit stereo I2S output at 48 kHz (pix domain, 25.2 MHz)
//   Each frame lasts 525 pixel cycles = 64 BCLK periods (3.072 MHz on
//   average; half-periods are split into 4 and 5 cycles with Bresenham).
//   LRCK = 0: left channel; the MSB goes out one BCLK after the LRCK
//   change (I2S format), 32 BCLK per channel. 'frame' starts a frame with l/r.
// ============================================================================
`default_nettype none
module i2s_tx (
    input  wire        clk,
    input  wire        rst,
    input  wire        frame,
    input  wire [15:0] l,
    input  wire [15:0] r,
    output reg         bclk,
    output reg         lrck,
    output reg         sdata
);
    reg [9:0]  pos;
    reg [9:0]  acc;
    reg [6:0]  half;                    // BCLK half-period (0..127)
    reg [63:0] sh;
    wire [9:0] acc_n = acc + 10'd128;
    always @(posedge clk) begin
        if (rst) begin
            bclk <= 1'b0; lrck <= 1'b0; sdata <= 1'b0;
            half <= 7'd0; acc <= 10'd0; pos <= 10'd524;
        end else if (frame) begin
            pos  <= 10'd0;
            acc  <= 10'd0;
            half <= 7'd0;
            bclk <= 1'b0;
            lrck <= 1'b0;
            sdata <= 1'b0;                          // I2S delay bit
            sh   <= {l, 16'd0, r, 16'd0};
        end else if (pos != 10'd524) begin
            pos <= pos + 10'd1;
            if (acc_n >= 10'd525) begin
                acc  <= acc_n - 10'd525;
                half <= half + 7'd1;
                bclk <= ~bclk;
                if (bclk) begin
                    // falling edge: the receiver samples on the rising one
                    // the bit for period k (k = half/2 + 1) of the current channel
                    sdata <= sh[63];
                    sh    <= {sh[62:0], 1'b0};
                    lrck  <= (half[6:1] >= 6'd31) && (half[6:1] != 6'd63);
                end
            end else
                acc <= acc_n;
        end
    end
endmodule
`default_nettype wire
