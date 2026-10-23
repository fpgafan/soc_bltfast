// ============================================================================
// tb_audio.v - audio + sdram_ctrl + modelo de SDRAM, dirigido por fichero
//   +ev=<f>   líneas "<n_muestra> <off_hex> <dato_hex>": escritura de registro
//             antes de calcular la muestra n (con el motor en reposo)
//   +n=<N>    muestras a generar ; +out=<f> salida {R,L} por muestra
// ============================================================================
`timescale 1ns/1ps
module tb_audio;
    reg clk = 0;
    always #5 clk = ~clk;
    reg sd_clk = 0;
    always @(clk) sd_clk <= #2 clk;
    reg rst = 1;

    reg         sel = 0, we = 0;
    reg  [11:0] a = 0;
    reg  [31:0] wd = 0;
    wire [31:0] rd;
    wire        irq;
    reg         tick = 0;
    wire        m_req, m_ack, m_rvalid, ov;
    wire [22:2] m_addr;
    wire [3:0]  m_len;
    wire [31:0] rdata;
    wire [15:0] ol, orr;

    audio u_aud (
        .clk(clk), .rst(rst), .sel(sel), .we(we), .a(a), .wd(wd), .rd(rd), .irq(irq),
        .tick48(tick), .ext(16'sd0), .m_req(m_req), .m_addr(m_addr), .m_len(m_len), .m_ack(m_ack),
        .m_rdata(rdata), .m_rvalid(m_rvalid), .out_valid(ov), .out_l(ol), .out_r(orr)
    );

    // tráfico competidor opcional en el maestro 0 (vídeo)
    reg v_req = 0; reg [22:2] v_addr = 0; reg vid_on = 0; integer vcnt = 0;
    wire [3:0] ack4, wnext4, rvalid4;
    always @(posedge clk) begin
        if (ack4[0]) v_req <= 0;
        vcnt <= vcnt + 1;
        if (vid_on && !v_req && (vcnt % 30) == 0) begin v_req <= 1; v_addr <= 21'h1F0000; end
    end

    wire        sd_cke, sd_cs_n, sd_ras_n, sd_cas_n, sd_we_n;
    wire [1:0]  sd_ba;
    wire [10:0] sd_a;
    wire [3:0]  sd_dqm;
    wire [31:0] sd_dq;
    wire        sd_ready;
    sdram_ctrl #(.CLK_MHZ(100), .INIT_US(2)) u_sd (
        .clk(clk), .rst(rst), .rd_lat(3'd2), .ready(sd_ready),
        .req({2'b00, m_req, v_req}), .we(4'b0000),
        .addr({42'd0, m_addr, v_addr}), .len({8'd0, m_len, 4'd15}),
        .ack(ack4), .wdata(128'd0), .wmask(16'd0),
        .wnext(wnext4), .rdata(rdata), .rvalid(rvalid4),
        .sd_cke(sd_cke), .sd_cs_n(sd_cs_n), .sd_ras_n(sd_ras_n), .sd_cas_n(sd_cas_n),
        .sd_we_n(sd_we_n), .sd_ba(sd_ba), .sd_a(sd_a), .sd_dqm(sd_dqm), .sd_dq(sd_dq)
    );
    assign m_ack = ack4[1]; assign m_rvalid = rvalid4[1];
    sdram_model u_mem (
        .clk(sd_clk), .cke(sd_cke), .cs_n(sd_cs_n), .ras_n(sd_ras_n), .cas_n(sd_cas_n),
        .we_n(sd_we_n), .ba(sd_ba), .a(sd_a), .dqm(sd_dqm), .dq(sd_dq)
    );

    task wr(input [11:0] off, input [31:0] d);
        begin
            @(posedge clk); sel <= 1; we <= 1; a <= off; wd <= d;
            @(posedge clk); sel <= 0; we <= 0;
        end
    endtask

    reg [8*256-1:0] fev, finit, fout;
    integer fd, fo, r, ns, off, dat, n = 100, k, maxc = 0, c0;
    reg have;
    initial begin
        if (!$value$plusargs("ev=%s", fev)) fev = "aud_ev.txt";
        if ($value$plusargs("init=%s", finit)) $readmemh(finit, u_mem.mem);
        if (!$value$plusargs("out=%s", fout)) fout = "aud_out.txt";
        if ($value$plusargs("n=%d", n)) ;
        if ($test$plusargs("vid")) vid_on = 1;
        repeat (5) @(posedge clk);
        rst <= 0;
        wait (sd_ready);
        fd = $fopen(fev, "r");
        fo = $fopen(fout, "w");
        have = 0;
        r = $fscanf(fd, "%d %h %h\n", ns, off, dat);
        have = (r == 3);
        for (k = 0; k < n; k = k + 1) begin
            while (have && ns <= k) begin
                wr(off[11:0], dat);
                r = $fscanf(fd, "%d %h %h\n", ns, off, dat);
                have = (r == 3);
            end
            @(posedge clk); tick <= 1;
            @(posedge clk); tick <= 0;
            c0 = $time;
            @(posedge ov);
            if (($time - c0) / 10 > maxc) maxc = ($time - c0) / 10;
            @(negedge clk);
            $fwrite(fo, "%04h%04h\n", orr, ol);
            if (($time - c0) / 10 > 2060) $display("AVISO: muestra %0d tardó %0d ciclos", k, ($time - c0) / 10);
        end
        $fclose(fo);
        $display("AUDIO: %0d muestras, máx %0d ciclos/muestra, errores SDRAM=%0d", n, maxc, u_mem.errors);
        $finish;
    end
endmodule
