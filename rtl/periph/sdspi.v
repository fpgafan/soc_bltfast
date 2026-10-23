// ============================================================================
// sdspi.v - SD card in SPI mode with hardware block transfers
//   +0x000 CTRL   RW [0] CS active (pin at 0), [15:8] divider:
//                    f_sck = f_clk / (2 * (DIV + 1))   (400 kHz for init,
//                    then DIV = 1 -> ~25 MHz)
//   +0x004 DATA   W: sends a byte (and receives another); R: last byte received
//   +0x008 STAT   R: [0] busy, [1] the last block ended on timeout,
//                    [2] card present (DAT3 with pull-up: unreliable)
//   +0x00C BLOCK  W: 1 = read block: sends 0xFF until the 0xFE token arrives
//                    (max. 65536 bytes), reads 512 bytes into the buffer + 2 CRC
//                    2 = write block: sends 0xFE, the 512 buffer bytes
//                    and 2 dummy CRC bytes (software reads the response)
//   +0x200..0x3FF BUF  512-byte buffer (little-endian words, R/W)
// ============================================================================
`default_nettype none
module sdspi (
    input  wire        clk,
    input  wire        rst,
    input  wire        sel,
    input  wire        we,
    input  wire [9:0]  a,
    input  wire [31:0] wd,
    output wire [31:0] rd,
    output reg         sd_clk,
    output reg         sd_mosi,
    input  wire        sd_miso,
    output wire        sd_cs_n
);
    reg        cs;
    reg [7:0]  div;
    reg [7:0]  rx;
    reg        tout;
    assign sd_cs_n = ~cs;

    // 128-word buffer
    reg [31:0] buf_m [0:127];
    reg        bw_e;
    reg [6:0]  bw_a;
    reg [31:0] bw_d;
    reg [6:0]  br_a;                // read pointer for block writes
    reg [31:0] br_q;
    reg [2:0]  bs;
    wire       blk_wr = (bs == 3'd4) || (bs == 3'd5);
    wire [6:0] br_ra = blk_wr ? br_a : a[8:2];   // the CPU reads with its own address
    always @(posedge clk) begin
        if (bw_e) buf_m[bw_a] <= bw_d;
        br_q <= buf_m[br_ra];
    end

    // ---------------------------------------------------------------- SPI byte
    reg        x_go;                // start of a byte
    reg [7:0]  x_tx;
    reg        x_busy;
    reg [7:0]  x_sh;
    reg [3:0]  x_bit;
    reg [7:0]  x_cnt;
    reg        x_done;
    reg [2:0]  miso_s;
    always @(posedge clk) miso_s <= {miso_s[1:0], sd_miso};

    always @(posedge clk) begin
        x_done <= 1'b0;
        if (rst) begin
            x_busy <= 1'b0; sd_clk <= 1'b0; sd_mosi <= 1'b1;
        end else if (x_go && !x_busy) begin
            x_busy  <= 1'b1;
            x_sh    <= x_tx;
            sd_mosi <= x_tx[7];
            x_bit   <= 4'd0;
            x_cnt   <= div;
            sd_clk  <= 1'b0;
        end else if (x_busy) begin
            if (x_cnt != 8'd0)
                x_cnt <= x_cnt - 8'd1;
            else begin
                x_cnt <= div;
                if (!sd_clk) begin
                    // rising edge: sample MISO
                    sd_clk <= 1'b1;
                    x_sh   <= {x_sh[6:0], miso_s[1]};
                end else begin
                    sd_clk <= 1'b0;
                    x_bit  <= x_bit + 4'd1;
                    if (x_bit == 4'd7) begin
                        x_busy  <= 1'b0;
                        x_done  <= 1'b1;
                        sd_mosi <= 1'b1;
                    end else
                        sd_mosi <= x_sh[7];
                end
            end
        end
    end

    // ---------------------------------------------------------------- sequencer
    localparam B_IDLE = 3'd0, B_BYTE = 3'd1, B_TOK = 3'd2, B_RD = 3'd3, B_WTOK = 3'd4,
               B_WR = 3'd5, B_CRC = 3'd6;
    reg [9:0]  bcnt;
    reg [15:0] tcnt;
    reg [31:0] wacc;
    reg        wpend;               // waiting for an x_done

    wire bus_wr = sel & we;
    always @(posedge clk) begin
        bw_e <= 1'b0;
        x_go <= 1'b0;
        if (rst) begin
            cs <= 1'b0; div <= 8'd124; bs <= B_IDLE; tout <= 1'b0; rx <= 8'hFF;
            wpend <= 1'b0;
        end else begin
            if (bus_wr) begin
                case (a[9:2])
                8'h00: begin cs <= wd[0]; div <= wd[15:8]; end
                8'h01: if (bs == B_IDLE) begin x_tx <= wd[7:0]; x_go <= 1'b1; bs <= B_BYTE; end
                8'h03: if (bs == B_IDLE) begin
                    tout <= 1'b0;
                    if (wd[1:0] == 2'd1) begin
                        tcnt <= 16'd0; x_tx <= 8'hFF; x_go <= 1'b1; bs <= B_TOK;
                    end else if (wd[1:0] == 2'd2) begin
                        x_tx <= 8'hFE; x_go <= 1'b1; bs <= B_WTOK; bcnt <= 10'd0;
                        br_a <= 7'd0;
                    end
                end
                default: ;
                endcase
                if (a[9]) begin
                    bw_e <= 1'b1; bw_a <= a[8:2]; bw_d <= wd;
                end
            end
            case (bs)
            B_BYTE: if (x_done) begin rx <= x_sh; bs <= B_IDLE; end
            B_TOK: if (x_done) begin
                rx <= x_sh;
                if (x_sh == 8'hFE) begin
                    bcnt <= 10'd0; x_tx <= 8'hFF; x_go <= 1'b1; bs <= B_RD;
                end else if (tcnt == 16'hFFFF) begin
                    tout <= 1'b1; bs <= B_IDLE;
                end else begin
                    tcnt <= tcnt + 16'd1; x_tx <= 8'hFF; x_go <= 1'b1;
                end
            end
            B_RD: if (x_done) begin
                wacc <= {x_sh, wacc[31:8]};
                if (bcnt[1:0] == 2'd3) begin
                    bw_e <= 1'b1; bw_a <= bcnt[8:2]; bw_d <= {x_sh, wacc[31:8]};
                end
                bcnt <= bcnt + 10'd1;
                x_tx <= 8'hFF; x_go <= 1'b1;
                if (bcnt == 10'd511) begin bcnt <= 10'd0; bs <= B_CRC; end
            end
            B_WTOK: if (x_done) begin
                // first data byte
                x_tx <= br_q[7:0]; x_go <= 1'b1; bcnt <= 10'd1; bs <= B_WR;
                br_a <= 7'd0;
            end
            B_WR: if (x_done) begin
                if (bcnt == 10'd512) begin
                    bcnt <= 10'd0; x_tx <= 8'hFF; x_go <= 1'b1; bs <= B_CRC;
                end else begin
                    case (bcnt[1:0])
                    2'd0: x_tx <= br_q[7:0];
                    2'd1: x_tx <= br_q[15:8];
                    2'd2: x_tx <= br_q[23:16];
                    default: x_tx <= br_q[31:24];
                    endcase
                    x_go <= 1'b1;
                    bcnt <= bcnt + 10'd1;
                    if (bcnt[1:0] == 2'd3) br_a <= bcnt[8:2] + 7'd1;
                end
            end
            B_CRC: if (x_done) begin
                rx <= x_sh;
                if (bcnt == 10'd1) bs <= B_IDLE;
                else begin bcnt <= 10'd1; x_tx <= 8'hFF; x_go <= 1'b1; end
            end
            default: ;
            endcase
        end
    end

    reg [31:0] rd_r;
    reg        rd_buf;
    always @(posedge clk) begin
        rd_buf <= a[9];
        case (a[9:2])
        8'h00: rd_r <= {16'd0, div, 7'd0, cs};
        8'h01: rd_r <= {24'd0, rx};
        8'h02: rd_r <= {29'd0, 1'b0, tout, bs != B_IDLE};
        default: rd_r <= 32'd0;
        endcase
    end
    assign rd = rd_buf ? br_q : rd_r;
endmodule
`default_nettype wire
