// ============================================================================
// tb_cpu.v - Testbench: cpu + sdram_ctrl + SDRAM model + minimal I/O
//   I/O: 0x8000_0000 console (W: character), 0x8000_0F00 tohost (end),
//        0x8000_0F04/08 trap information, 0x8000_0010 (R) counter.
//   +prog=<hex>   program loaded into SDRAM (0x4000_0000)
//   +rom=<hex>    ROM (default: jumps to 0x4000_0000)
//   +maxcyc=<n>   cycle limit
// ============================================================================
`timescale 1ns/1ps
module tb_cpu;
    parameter real PERIOD = 10.0;        // 100 MHz
    parameter real SD_PHASE = 2.0;       // SDRAM clock delay (ns)
    parameter RD_LAT = 2;

    reg clk = 0;
    always #(PERIOD/2) clk = ~clk;
    reg sd_clk = 0;
    always @(clk) sd_clk <= #(SD_PHASE) clk;

    reg rst = 1;
    integer cyc = 0;
    integer maxcyc = 2000000;

    // ---------------------------------------------------------------- CPU
    wire        m_req, m_we, m_ack, m_wnext, m_rvalid;
    wire [22:2] m_addr;
    wire [3:0]  m_len, m_wmask;
    wire [31:0] m_wdata, m_rdata;
    wire        io_req, io_we;
    wire [31:0] io_a, io_wd;
    wire [3:0]  io_ws;
    reg         io_ack = 0;
    reg  [31:0] io_rd = 0;
    reg         irq_ext = 0, irq_timer = 0, irq_soft = 0;
    wire [63:0] instret;

    cpu #(.ROM_FILE("rom_jump.hex")) u_cpu (
        .clk(clk), .rst(rst),
        .m_req(m_req), .m_we(m_we), .m_addr(m_addr), .m_len(m_len), .m_ack(m_ack),
        .m_wdata(m_wdata), .m_wmask(m_wmask), .m_wnext(m_wnext),
        .m_rdata(m_rdata), .m_rvalid(m_rvalid),
        .io_req(io_req), .io_we(io_we), .io_a(io_a), .io_wd(io_wd), .io_ws(io_ws),
        .io_ack(io_ack), .io_rd(io_rd),
        .irq_ext(irq_ext), .irq_timer(irq_timer), .irq_soft(irq_soft),
        .instret(instret)
    );

    // ---------------------------------------------------------------- SDRAM
    wire        sd_cke, sd_cs_n, sd_ras_n, sd_cas_n, sd_we_n;
    wire [1:0]  sd_ba;
    wire [10:0] sd_a;
    wire [3:0]  sd_dqm;
    wire [31:0] sd_dq;
    wire [3:0]  ack4, wnext4, rvalid4;
    wire [31:0] rdata;
    wire        sd_ready;

    sdram_ctrl #(.CLK_MHZ(100), .INIT_US(2)) u_sd (
        .clk(clk), .rst(rst), .rd_lat(RD_LAT[2:0]), .ready(sd_ready),
        .req({1'b0, m_req, 2'b00}), .we({1'b0, m_we, 2'b00}),
        .addr({21'd0, m_addr, 42'd0}), .len({4'd0, m_len, 8'd0}),
        .ack(ack4), .wdata({32'd0, m_wdata, 64'd0}), .wmask({4'd0, m_wmask, 8'd0}),
        .wnext(wnext4), .rdata(rdata), .rvalid(rvalid4),
        .sd_cke(sd_cke), .sd_cs_n(sd_cs_n), .sd_ras_n(sd_ras_n), .sd_cas_n(sd_cas_n),
        .sd_we_n(sd_we_n), .sd_ba(sd_ba), .sd_a(sd_a), .sd_dqm(sd_dqm), .sd_dq(sd_dq)
    );
    assign m_ack    = ack4[2];
    assign m_wnext  = wnext4[2];
    assign m_rvalid = rvalid4[2];
    assign m_rdata  = rdata;

    sdram_model u_mem (
        .clk(sd_clk), .cke(sd_cke), .cs_n(sd_cs_n), .ras_n(sd_ras_n), .cas_n(sd_cas_n),
        .we_n(sd_we_n), .ba(sd_ba), .a(sd_a), .dqm(sd_dqm), .dq(sd_dq)
    );

    // ---------------------------------------------------------------- I/O
    reg [8*256-1:0] progfile;
    integer trap_info0 = 0, trap_info1 = 0;
    always @(posedge clk) begin
        io_ack <= 1'b0;
        if (io_req) begin
            io_ack <= 1'b1;
            io_rd  <= (io_a == 32'h8000_0010) ? cyc : 32'h0;
            if (io_we) begin
                case (io_a)
                32'h8000_0000: $write("%c", io_wd[7:0]);
                32'h8000_0F04: trap_info0 = io_wd;
                32'h8000_0F08: trap_info1 = io_wd;
                32'h8000_0F00: begin
                    if (io_wd == 32'd1) begin
                        $display("PASS  cycles=%0d instr=%0d CPI=%0.3f", cyc, instret,
                                 1.0 * cyc / instret);
                        if ($test$plusargs("dump")) begin
                            $writememh("rand_data.hex", u_mem.mem, 32'h40000, 32'h40000 + 1023);
                            $writememh("rand_sig.hex",  u_mem.mem, 32'h60000, 32'h60000 + 31);
                        end
                    end
                    else if (io_wd == 32'd3)
                        $display("FAIL  unexpected trap mcause=%0d", trap_info1);
                    else
                        $display("FAIL  test %0d", io_wd >> 1);
                    if (u_mem.errors) $display("SDRAM: %0d timing errors", u_mem.errors);
                    $finish;
                end
                default: ;
                endcase
            end
        end
    end

    initial begin
        if ($value$plusargs("prog=%s", progfile)) $readmemh(progfile, u_mem.mem);
        if ($value$plusargs("maxcyc=%d", maxcyc)) ;
        repeat (5) @(posedge clk);
        rst <= 0;
    end
    reg trace = 0;
    initial if ($test$plusargs("trace")) trace = 1;
    always @(posedge clk) if (trace && !rst) begin
        if (u_cpu.u_core.liveM)
            $display("%6d M pc=%h res=%h rp=%b tr=%b ld=%b st=%b hit=%b addr=%h",
                     cyc, u_cpu.u_core.pcM, u_cpu.u_core.resM, u_cpu.u_core.replay,
                     u_cpu.u_core.trap, u_cpu.u_core.ldM, u_cpu.u_core.stM, u_cpu.u_core.dc_hit,
                     u_cpu.u_core.addrM);
        if (u_cpu.u_core.rf_we)
            $display("%6d   W x%0d <= %h", cyc, u_cpu.u_core.rdW, u_cpu.u_core.resW);
    end
    always @(posedge clk) begin
        cyc <= cyc + 1;
        if (cyc == maxcyc) begin
            $display("TIMEOUT pc=%h", u_cpu.u_core.pcM);
            $finish;
        end
    end
endmodule
