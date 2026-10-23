// ============================================================================
// gamepad.v - Automatic reading of 2 SNES (or NES) pads every ~1 ms
//   +0x00 PAD0  R [15:0] buttons (1 = pressed)
//                 SNES: B Y Select Start Up Down Left Right A X L R (bits 0..11)
//                 NES : A B Select Start Up Down Left Right (bits 0..7)
//   +0x04 PAD1  R
//   +0x08 CNT   R  completed reads
// ============================================================================
`default_nettype none
module gamepad #(
    parameter CLK_HZ = 90_000_000
)(
    input  wire        clk,
    input  wire        rst,
    input  wire [3:0]  a,
    output reg  [31:0] rd,
    output reg  [1:0]  pad_latch,
    output reg  [1:0]  pad_clk,
    input  wire [1:0]  pad_data
);
    localparam integer T6US  = CLK_HZ / 166_667;       // ~6 us
    localparam integer TPOLL = CLK_HZ / 1000;          // 1 ms
    reg [15:0] p0, p1, s0, s1;
    reg [15:0] t;
    reg [19:0] pt;
    reg [5:0]  ph;
    reg [31:0] cnt;
    reg [1:0]  d_s0, d_s1;
    always @(posedge clk) begin d_s0 <= pad_data; d_s1 <= d_s0; end

    always @(posedge clk) begin
        if (rst) begin
            pad_latch <= 2'b00; pad_clk <= 2'b11; ph <= 6'd0; t <= 16'd0; pt <= 20'd0;
            p0 <= 16'd0; p1 <= 16'd0; cnt <= 32'd0;
        end else begin
            if (ph == 6'd0) begin
                if (pt == TPOLL[19:0]) begin
                    pt <= 20'd0; ph <= 6'd1; t <= 16'd0; pad_latch <= 2'b11;
                end else
                    pt <= pt + 20'd1;
            end else if (t != T6US[15:0])
                t <= t + 16'd1;
            else begin
                t  <= 16'd0;
                ph <= ph + 6'd1;
                if (ph == 6'd2)
                    pad_latch <= 2'b00;                 // latch high for 12 us
                else if (ph >= 6'd3) begin
                    // odd phases: clock low and bit read; even: clock high
                    if (ph[0]) begin
                        pad_clk <= 2'b00;
                        s0 <= {~d_s1[0], s0[15:1]};
                        s1 <= {~d_s1[1], s1[15:1]};
                    end else
                        pad_clk <= 2'b11;
                    if (ph == 6'd34) begin
                        ph  <= 6'd0;
                        p0  <= s0;
                        p1  <= s1;
                        cnt <= cnt + 32'd1;
                    end
                end
            end
        end
        case (a[3:2])
        2'd0:    rd <= {16'd0, p0};
        2'd1:    rd <= {16'd0, p1};
        default: rd <= cnt;
        endcase
    end
endmodule
`default_nettype wire
