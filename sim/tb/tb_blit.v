// ============================================================================
// tb_blit.v - blitter + sdram_ctrl + modelo de SDRAM, dirigido por fichero
//   +cmds=<f>  líneas: "W <off> <dato>" (registro), "I" (esperar a que acabe)
//   +init=<f>  contenido inicial de la SDRAM ; +dump=<f> volcado final (1 MB)
//   +vid       genera tráfico de vídeo en el maestro 0 (prioridad mayor)
// ============================================================================
`timescale 1ns/1ps
module tb_blit;
    reg clk = 0;
    always #5 clk = ~clk;
    reg sd_clk = 0;
    always @(clk) sd_clk <= #2 clk;
    reg rst = 1;

    // ---------------------------------------------------------------- blitter
    reg         sel = 0, we = 0;
    reg  [5:0]  a = 0;
    reg  [31:0] wd = 0;
    wire [31:0] rd;
    wire        ack, irq;
    wire        b_req, b_we, b_ack, b_wnext, b_rvalid;
    wire [22:2] b_addr;
    wire [3:0]  b_len, b_wmask;
    wire [31:0] b_wdata, rdata;

    blitter u_blt (
        .clk(clk), .rst(rst), .sel(sel), .we(we), .a(a), .wd(wd), .rd(rd), .ack(ack), .irq(irq),
        .m_req(b_req), .m_we(b_we), .m_addr(b_addr), .m_len(b_len), .m_ack(b_ack),
        .m_wdata(b_wdata), .m_wmask(b_wmask), .m_wnext(b_wnext),
        .m_rdata(rdata), .m_rvalid(b_rvalid)
    );

    // ---------------------------------------------------------------- tráfico de vídeo
    reg         v_req = 0;
    reg  [22:2] v_addr = 0;
    reg         vid_on = 0;
    integer     vcnt = 0;
    wire [3:0]  ack4, wnext4, rvalid4;
    always @(posedge clk) begin
        if (ack4[0]) v_req <= 0;
        vcnt <= vcnt + 1;
        if (vid_on && !v_req && (vcnt % 40) == 0) begin
            v_req  <= 1;
            v_addr <= 21'h1F0000 + (($random & 21'h3F) << 4);
        end
    end

    // ---------------------------------------------------------------- SDRAM
    wire        sd_cke, sd_cs_n, sd_ras_n, sd_cas_n, sd_we_n;
    wire [1:0]  sd_ba;
    wire [10:0] sd_a;
    wire [3:0]  sd_dqm;
    wire [31:0] sd_dq;
    wire        sd_ready;
    sdram_ctrl #(.CLK_MHZ(100), .INIT_US(2)) u_sd (
        .clk(clk), .rst(rst), .rd_lat(3'd2), .ready(sd_ready),
        .req({b_req, 2'b00, v_req}), .we({b_we, 3'b000}),
        .addr({b_addr, 42'd0, v_addr}), .len({b_len, 8'd0, 4'd15}),
        .ack(ack4), .wdata({b_wdata, 96'd0}), .wmask({b_wmask, 12'd0}),
        .wnext(wnext4), .rdata(rdata), .rvalid(rvalid4),
        .sd_cke(sd_cke), .sd_cs_n(sd_cs_n), .sd_ras_n(sd_ras_n), .sd_cas_n(sd_cas_n),
        .sd_we_n(sd_we_n), .sd_ba(sd_ba), .sd_a(sd_a), .sd_dqm(sd_dqm), .sd_dq(sd_dq)
    );
    assign b_ack = ack4[3]; assign b_wnext = wnext4[3]; assign b_rvalid = rvalid4[3];
    sdram_model u_mem (
        .clk(sd_clk), .cke(sd_cke), .cs_n(sd_cs_n), .ras_n(sd_ras_n), .cas_n(sd_cas_n),
        .we_n(sd_we_n), .ba(sd_ba), .a(sd_a), .dqm(sd_dqm), .dq(sd_dq)
    );

    // ---------------------------------------------------------------- comandos
    task wr(input [5:0] off, input [31:0] d);
        begin
            @(posedge clk); sel <= 1; we <= 1; a <= off; wd <= d;
            @(posedge clk); sel <= 0; we <= 0;
            while (!ack) @(posedge clk);
        end
    endtask
    task rdreg(input [5:0] off, output [31:0] d);
        begin
            @(posedge clk); sel <= 1; we <= 0; a <= off;
            @(posedge clk); sel <= 0;
            while (!ack) @(posedge clk);
            d = rd;
        end
    endtask

    reg [8*256-1:0] fcmd, finit, fdump;
    integer fd, r, off, dat, ncmd = 0, t0;
    reg [31:0] st;
    reg [8*4-1:0] tok;
    initial begin
        if (!$value$plusargs("cmds=%s", fcmd)) fcmd = "cmds.txt";
        if ($value$plusargs("init=%s", finit)) $readmemh(finit, u_mem.mem);
        if (!$value$plusargs("dump=%s", fdump)) fdump = "dump.hex";
        if ($test$plusargs("vid")) vid_on = 1;
        repeat (5) @(posedge clk);
        rst <= 0;
        wait (sd_ready);
        t0 = $time;
        fd = $fopen(fcmd, "r");
        while (!$feof(fd)) begin
            r = $fscanf(fd, "%s", tok);
            if (r == 1) begin
                if (tok == "W") begin
                    r = $fscanf(fd, "%h %h\n", off, dat);
                    wr(off[5:0], dat);
                    if (off == 32'h38) ncmd = ncmd + 1;
                end else if (tok == "I") begin
                    st = 1;
                    while (st[0]) begin
                        repeat (20) @(posedge clk);
                        rdreg(6'h00, st);
                    end
                end
            end
        end
        st = 1;
        while (st[0]) begin
            repeat (20) @(posedge clk);
            rdreg(6'h00, st);
        end
        $display("BLIT: %0d comandos en %0d ciclos, terminados=%0d, errores SDRAM=%0d",
                 ncmd, ($time - t0) / 10, st[31:16], u_mem.errors);
        $writememh(fdump, u_mem.mem, 0, 262143);
        $finish;
    end
    initial begin
        #(100_000_000);
        $display("TIMEOUT es=%0d cmds=%0d done=%0d rd_left=%0d rd_got=%0d rd_tot=%0d g_w=%0d g_nw=%0d wr_left=%0d",
                 u_blt.es, ncmd, u_blt.done_cnt, u_blt.rd_left, u_blt.rd_got, u_blt.rd_tot,
                 u_blt.g_w, u_blt.g_nw, u_blt.wr_left);
        $finish;
    end
endmodule
