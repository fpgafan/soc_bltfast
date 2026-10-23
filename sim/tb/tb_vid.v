// ============================================================================
// tb_vid.v - video + hdmi_tx + sdram_ctrl + SDRAM model
//   Initial framebuffer (+init), random palette, 48 kHz audio samples
//   (counter), and dump of the TMDS words of a complete frame (+out).
//   +sx=<n> +sy=<n> scroll ; +wrapw=<n> +wraph=<n> ; +stride=<n>
// ============================================================================
`timescale 1ns/1ps
module tb_vid;
    reg clk = 0;  always #5 clk = ~clk;              // 100 MHz
    reg cp = 0;   always #19.841 cp = ~cp;           // 25.2 MHz
    reg sd_clk = 0; always @(clk) sd_clk <= #2 clk;
    reg rst = 1, rst_pix = 1;

    reg         sel = 0, psel = 0, we = 0;
    reg  [5:0]  a = 0;
    reg  [7:0]  pa = 0;
    reg  [31:0] wd = 0;
    wire [31:0] rd;
    wire        ivb, irs;
    wire        m_req, m_ack, m_rvalid;
    wire [22:2] m_addr;
    wire [3:0]  m_len;
    wire [31:0] rdata;
    wire [23:0] rgb;
    wire        hs, vs, de, hm;
    wire [9:0]  hc, vc;

    video u_vid (
        .clk(clk), .rst(rst), .clk_pix(cp), .rst_pix(rst_pix),
        .sel(sel), .pal_sel(psel), .we(we), .a(a), .pal_a(pa), .wd(wd), .rd(rd),
        .irq_vblank(ivb), .irq_raster(irs),
        .m_req(m_req), .m_addr(m_addr), .m_len(m_len), .m_ack(m_ack),
        .m_rdata(rdata), .m_rvalid(m_rvalid),
        .rgb(rgb), .hsync(hs), .vsync(vs), .de(de), .pix_hcount(hc), .pix_vcount(vc),
        .hdmi_mode(hm)
    );

    // audio samples: 48 kHz counter (525 pixel cycles)
    reg [9:0]  t48 = 0;
    reg        awe = 0;
    reg [15:0] smp = 16'h1000;
    always @(posedge cp) begin
        awe <= 0;
        if (t48 == 524) begin t48 <= 0; awe <= 1; smp <= smp + 16'd1; end
        else t48 <= t48 + 1;
    end
    wire [29:0] tw;
    hdmi_tx u_hdmi (
        .clk_pix(cp), .clk_ser(1'b0), .rst(rst_pix), .hdmi_en(hm),
        .rgb(rgb), .de(de), .hsync(hs), .vsync(vs), .hc(hc), .vc(vc),
        .aud_we(awe), .aud_l(smp), .aud_r(~smp),
        .tmds_clk_p(), .tmds_clk_n(), .tmds_d_p(), .tmds_d_n(), .tmds_word(tw)
    );

    wire [3:0] ack4, wnext4, rvalid4;
    wire        sd_cke, sd_cs_n, sd_ras_n, sd_cas_n, sd_we_n, sd_ready;
    wire [1:0]  sd_ba;
    wire [10:0] sd_a;
    wire [3:0]  sd_dqm;
    wire [31:0] sd_dq;
    sdram_ctrl #(.CLK_MHZ(100), .INIT_US(2)) u_sd (
        .clk(clk), .rst(rst), .rd_lat(3'd2), .ready(sd_ready),
        .req({3'b000, m_req}), .we(4'b0000), .addr({63'd0, m_addr}), .len({12'd0, m_len}),
        .ack(ack4), .wdata(128'd0), .wmask(16'd0), .wnext(wnext4), .rdata(rdata), .rvalid(rvalid4),
        .sd_cke(sd_cke), .sd_cs_n(sd_cs_n), .sd_ras_n(sd_ras_n), .sd_cas_n(sd_cas_n),
        .sd_we_n(sd_we_n), .sd_ba(sd_ba), .sd_a(sd_a), .sd_dqm(sd_dqm), .sd_dq(sd_dq)
    );
    assign m_ack = ack4[0]; assign m_rvalid = rvalid4[0];
    sdram_model u_mem (
        .clk(sd_clk), .cke(sd_cke), .cs_n(sd_cs_n), .ras_n(sd_ras_n), .cas_n(sd_cas_n),
        .we_n(sd_we_n), .ba(sd_ba), .a(sd_a), .dqm(sd_dqm), .dq(sd_dq)
    );

    task wr(input [5:0] o, input [31:0] d);
        begin @(posedge clk); sel <= 1; we <= 1; a <= o; wd <= d; @(posedge clk); sel <= 0; we <= 0; end
    endtask
    task wp(input [7:0] i, input [31:0] d);
        begin @(posedge clk); psel <= 1; we <= 1; pa <= i; wd <= d; @(posedge clk); psel <= 0; we <= 0; end
    endtask

    reg [8*256-1:0] finit, fout, fpal;
    reg [31:0] palv [0:255];
    integer i, fo, sx = 0, sy = 0, ww = 0, wh = 0, stride = 640, frames = 0;
    initial begin
        if ($value$plusargs("init=%s", finit)) $readmemh(finit, u_mem.mem);
        if (!$value$plusargs("out=%s", fout)) fout = "tmds.txt";
        if ($value$plusargs("pal=%s", fpal)) $readmemh(fpal, palv);
        if ($value$plusargs("sx=%d", sx)) ;
        if ($value$plusargs("sy=%d", sy)) ;
        if ($value$plusargs("wrapw=%d", ww)) ;
        if ($value$plusargs("wraph=%d", wh)) ;
        if ($value$plusargs("stride=%d", stride)) ;
        repeat (4) @(posedge clk);
        rst <= 0;
        repeat (20) @(posedge cp);
        rst_pix <= 0;
        for (i = 0; i < 256; i = i + 1) wp(i, palv[i]);
        wr(6'h08, stride); wr(6'h0C, sx); wr(6'h10, sy); wr(6'h14, ww); wr(6'h18, wh);
        wr(6'h00, 32'h5);
        // the first complete frame applies the registers; the second one is recorded
        @(posedge ivb); @(posedge ivb);
        fo = $fopen(fout, "w");
        @(posedge cp);
        while (!(hc == 10'd0 && vc == 10'd524)) @(posedge cp);
        for (i = 0; i < 800 * 526; i = i + 1) begin
            @(posedge cp);
            $fwrite(fo, "%08h\n", tw);
        end
        $fclose(fo);
        $display("VID: done, SDRAM errors=%0d", u_mem.errors);
        $finish;
    end
endmodule
