// ============================================================================
// soc_top.v - SoC "bltfast" para Sipeed Tang Nano 20K (GW2AR-LV18QN88C8/I7)
//
//   CPU    : RV32IM_Zicsr, 6 etapas, icache 8 KB + dcache 8 KB, 90 MHz
//   RAM    : SDRAM embebida 8 MB (4 maestros: vídeo > sonido > CPU <-> 2D)
//   Vídeo  : 640x480@60 8 bpp con paleta, scroll por hardware, HDMI con audio
//   2D     : blitter con cola de comandos (relleno, copia escalada/espejo,
//            transparencia, 1 bpp, líneas)
//   Sonido : 32 voces wavetable/PCM por DMA, ADSR, 48 kHz (HDMI + I2S)
//   E/S    : UART, SD (SPI), 2 mandos SNES/NES, teclado PS/2, LEDs, botones
//
//   Mapa de memoria:
//     0x0000_0000  ROM de arranque (8 KB, cacheable)
//     0x1000_0000  RAM interna (4 KB, sin caché: pila del cargador)
//     0x4000_0000  SDRAM 8 MB (cacheable)     0x5000_0000  alias sin caché
//     0x8000_0000  sysctl        0x8000_1000  UART        0x8000_2000  vídeo
//     0x8000_3000  paleta        0x8000_4000  blitter     0x8000_5000  sonido
//     0x8000_6000  SD            0x8000_7000  mandos      0x8000_8000  PS/2
//     0x8000_9000  FM (OPL2)
//   Interrupciones externas (sysctl IRQ_PEND/IRQ_EN):
//     0 UART RX (nivel), 1 VBLANK, 2 RASTER, 3 blitter (flanco), 4 sonido,
//     5 PS/2 (nivel)
// ============================================================================
`default_nettype none
module soc_top #(
    parameter CLK_HZ   = 90_000_000,
    parameter ROM_FILE = "sw/build/boot.hex"
)(
    input  wire        clk_27m,
    input  wire [1:0]  btn,
    output wire [5:0]  led_n,
    output wire        uart_tx,
    input  wire        uart_rx,
    // HDMI
    output wire        tmds_clk_p, tmds_clk_n,
    output wire [2:0]  tmds_d_p,   tmds_d_n,
    // audio de la placa (I2S + amplificador)
    output wire        i2s_bclk,
    output wire        i2s_lrck,
    output wire        i2s_data,
    output wire        pa_en,
    // tarjeta SD (SPI)
    output wire        sd_clk,
    output wire        sd_cmd,
    input  wire        sd_dat0,
    output wire        sd_dat3,
    // mandos SNES/NES
    output wire [1:0]  pad_latch,
    output wire [1:0]  pad_clk,
    input  wire [1:0]  pad_data,
    // teclado PS/2
    input  wire        ps2_clk,
    input  wire        ps2_data,
    // SDRAM embebida (nombres obligatorios para que Gowin la enlace)
    output wire        O_sdram_clk,
    output wire        O_sdram_cke,
    output wire        O_sdram_cs_n,
    output wire        O_sdram_cas_n,
    output wire        O_sdram_ras_n,
    output wire        O_sdram_wen_n,
    output wire [3:0]  O_sdram_dqm,
    output wire [10:0] O_sdram_addr,
    output wire [1:0]  O_sdram_ba,
    inout  wire [31:0] IO_sdram_dq
);
    // ------------------------------------------------------------------ relojes
    wire clk, clk_sd, clk_ser, clk_pix, locked;
    wire [3:0] sd_phase;
    clocks u_clk (
        .clk_27m(clk_27m), .sd_phase(sd_phase),
        .clk_sys(clk), .clk_sd(clk_sd), .clk_ser(clk_ser), .clk_pix(clk_pix),
        .locked(locked)
    );
    assign O_sdram_clk = clk_sd;

    // ------------------------------------------------------------------ reset
    reg [7:0] rst_cnt = 8'd0;
    reg       rst = 1'b1;
    wire      soft_reset, uart_reset;
    always @(posedge clk or negedge locked) begin
        if (!locked) begin
            rst_cnt <= 8'd0;
            rst     <= 1'b1;
        end else if (soft_reset | uart_reset) begin
            rst_cnt <= 8'd0;
            rst     <= 1'b1;
        end else if (rst_cnt != 8'hFF) begin
            rst_cnt <= rst_cnt + 8'd1;
            rst     <= 1'b1;
        end else
            rst <= 1'b0;
    end
    reg [2:0] rst_pix_s = 3'b111;
    always @(posedge clk_pix) rst_pix_s <= {rst_pix_s[1:0], rst};
    wire rst_pix = rst_pix_s[2];

    // ------------------------------------------------------------------ SDRAM
    wire        v_req, a_req, c_req, b_req;
    wire        c_we, b_we;
    wire [22:2] v_addr, a_addr, c_addr, b_addr;
    wire [3:0]  v_len, a_len, c_len, b_len;
    wire [31:0] c_wdata, b_wdata, sd_rdata;
    wire [3:0]  c_wmask, b_wmask;
    wire [3:0]  sd_ack, sd_wnext, sd_rvalid;
    wire [2:0]  sd_rdlat;
    wire        sd_ready;
    sdram_ctrl #(.CLK_MHZ(CLK_HZ / 1_000_000)) u_sd (
        .clk(clk), .rst(rst), .rd_lat(sd_rdlat), .ready(sd_ready),
        .req({b_req, c_req, a_req, v_req}), .we({b_we, c_we, 2'b00}),
        .addr({b_addr, c_addr, a_addr, v_addr}), .len({b_len, c_len, a_len, v_len}),
        .ack(sd_ack), .wdata({b_wdata, c_wdata, 64'd0}), .wmask({b_wmask, c_wmask, 8'd0}),
        .wnext(sd_wnext), .rdata(sd_rdata), .rvalid(sd_rvalid),
        .sd_cke(O_sdram_cke), .sd_cs_n(O_sdram_cs_n), .sd_ras_n(O_sdram_ras_n),
        .sd_cas_n(O_sdram_cas_n), .sd_we_n(O_sdram_wen_n), .sd_ba(O_sdram_ba),
        .sd_a(O_sdram_addr), .sd_dqm(O_sdram_dqm), .sd_dq(IO_sdram_dq)
    );

    // ------------------------------------------------------------------ CPU
    wire        io_req, io_we;
    wire [31:0] io_a, io_wd;
    wire [3:0]  io_ws;
    wire        io_ack;
    reg  [31:0] io_rd;
    wire        meip, mtip, msip;
    wire [63:0] instret;
    cpu #(.ROM_FILE(ROM_FILE)) u_cpu (
        .clk(clk), .rst(rst),
        .m_req(c_req), .m_we(c_we), .m_addr(c_addr), .m_len(c_len), .m_ack(sd_ack[2]),
        .m_wdata(c_wdata), .m_wmask(c_wmask), .m_wnext(sd_wnext[2]),
        .m_rdata(sd_rdata), .m_rvalid(sd_rvalid[2]),
        .io_req(io_req), .io_we(io_we), .io_a(io_a), .io_wd(io_wd), .io_ws(io_ws),
        .io_ack(io_ack), .io_rd(io_rd),
        .irq_ext(meip), .irq_timer(mtip), .irq_soft(msip),
        .instret(instret)
    );

    // ------------------------------------------------------------------ bus de E/S
    // La petición de la CPU se registra una vez (r_*) antes de decodificarla:
    // así ningún periférico ve la lógica de la unidad de memoria en su camino.
    reg         r_req, r_we;
    reg  [31:0] r_a, r_wd;
    reg  [3:0]  r_ws;
    always @(posedge clk) begin
        r_req <= io_req & ~rst;
        if (io_req) begin r_we <= io_we; r_a <= io_a; r_wd <= io_wd; r_ws <= io_ws; end
    end
    // RAM interna de 4 KB (0x1000_0000), un carril por byte
    wire s_bram = r_req & (r_a[31:28] == 4'h1);
    reg  [7:0] br0 [0:1023], br1 [0:1023], br2 [0:1023], br3 [0:1023];
    reg  [31:0] rd_bram;
    always @(posedge clk) begin
        if (s_bram & r_we & r_ws[0]) br0[r_a[11:2]] <= r_wd[7:0];
        if (s_bram & r_we & r_ws[1]) br1[r_a[11:2]] <= r_wd[15:8];
        if (s_bram & r_we & r_ws[2]) br2[r_a[11:2]] <= r_wd[23:16];
        if (s_bram & r_we & r_ws[3]) br3[r_a[11:2]] <= r_wd[31:24];
    end
    always @(posedge clk) rd_bram <= {br3[r_a[11:2]], br2[r_a[11:2]], br1[r_a[11:2]], br0[r_a[11:2]]};
    wire [3:0] dsel = r_a[15:12];
    wire io_dev = (r_a[31:16] == 16'h8000);
    wire s_sys  = r_req & io_dev & (dsel == 4'h0);
    wire s_uart = r_req & io_dev & (dsel == 4'h1);
    wire s_vid  = r_req & io_dev & (dsel == 4'h2);
    wire s_pal  = r_req & io_dev & (dsel == 4'h3);
    wire s_blt  = r_req & io_dev & (dsel == 4'h4);
    wire s_aud  = r_req & io_dev & (dsel == 4'h5);
    wire s_sd   = r_req & io_dev & (dsel == 4'h6);
    wire s_pad  = r_req & io_dev & (dsel == 4'h7);
    wire s_ps2  = r_req & io_dev & (dsel == 4'h8);
    wire s_opl  = r_req & io_dev & (dsel == 4'h9);
    reg  [3:0] rsel;
    reg        ack_q;
    wire       blt_ack;
    always @(posedge clk) begin
        ack_q <= r_req & ~s_blt;                     // el blitter da su propio ack
        if (r_req) rsel <= io_dev ? dsel : (r_a[31:28] == 4'h1) ? 4'hE : 4'hF;
    end
    assign io_ack = ack_q | blt_ack;
    wire [31:0] rd_sys, rd_uart, rd_vid, rd_blt, rd_aud, rd_sd, rd_pad, rd_ps2, rd_opl;
    always @(*) begin
        case (rsel)
        4'h0: io_rd = rd_sys;
        4'h1: io_rd = rd_uart;
        4'h2: io_rd = rd_vid;
        4'h4: io_rd = rd_blt;
        4'h5: io_rd = rd_aud;
        4'h6: io_rd = rd_sd;
        4'h7: io_rd = rd_pad;
        4'h8: io_rd = rd_ps2;
        4'h9: io_rd = rd_opl;
        4'hE: io_rd = rd_bram;
        default: io_rd = 32'd0;
        endcase
    end

    // ------------------------------------------------------------------ sistema
    wire        uart_irq, vbl_irq, ras_irq, blt_irq, aud_irq, ps2_irq;
    wire [5:0]  led;
    sysctl #(.CLK_HZ(CLK_HZ)) u_sys (
        .clk(clk), .rst(rst), .sel(s_sys), .we(r_we), .a(r_a[5:0]),
        .wd(r_wd), .rd(rd_sys), .led(led), .btn(btn),
        .irq_lvl({10'd0, ps2_irq, aud_irq, 3'd0, uart_irq}),
        .irq_edge({12'd0, blt_irq, ras_irq, vbl_irq, 1'b0}),
        .meip(meip), .mtip(mtip), .msip(msip),
        .sd_rdlat(sd_rdlat), .sd_phase(sd_phase), .sd_ready(sd_ready),
        .soft_reset(soft_reset), .pa_en(pa_en)
    );
    assign led_n = ~led;

    uart #(.CLK_HZ(CLK_HZ)) u_uart (
        .clk(clk), .rst(rst), .sel(s_uart), .we(r_we), .a(r_a[3:0]),
        .wd(r_wd), .rd(rd_uart), .irq(uart_irq), .sw_reset(uart_reset),
        .rxd(uart_rx), .txd(uart_tx)
    );

    // ------------------------------------------------------------------ vídeo
    wire [23:0] rgb;
    wire        de, hsync, vsync, hdmi_mode;
    wire [9:0]  hc, vc;
    video u_vid (
        .clk(clk), .rst(rst), .clk_pix(clk_pix), .rst_pix(rst_pix),
        .sel(s_vid), .pal_sel(s_pal), .we(r_we), .a(r_a[5:0]), .pal_a(r_a[9:2]),
        .wd(r_wd), .rd(rd_vid), .irq_vblank(vbl_irq), .irq_raster(ras_irq),
        .m_req(v_req), .m_addr(v_addr), .m_len(v_len), .m_ack(sd_ack[0]),
        .m_rdata(sd_rdata), .m_rvalid(sd_rvalid[0]),
        .rgb(rgb), .hsync(hsync), .vsync(vsync), .de(de),
        .pix_hcount(hc), .pix_vcount(vc), .hdmi_mode(hdmi_mode)
    );

    // ------------------------------------------------------------------ blitter
    blitter u_blt (
        .clk(clk), .rst(rst), .sel(s_blt), .we(r_we), .a(r_a[5:0]), .wd(r_wd),
        .rd(rd_blt), .ack(blt_ack), .irq(blt_irq),
        .m_req(b_req), .m_we(b_we), .m_addr(b_addr), .m_len(b_len), .m_ack(sd_ack[3]),
        .m_wdata(b_wdata), .m_wmask(b_wmask), .m_wnext(sd_wnext[3]),
        .m_rdata(sd_rdata), .m_rvalid(sd_rvalid[3])
    );

    // ------------------------------------------------------------------ sonido
    // tick de 48 kHz exactos: 25,2 MHz / 525 (dominio pix) -> sys
    reg [9:0] t48 = 10'd0;
    reg       t48_tgl = 1'b0;
    always @(posedge clk_pix) begin
        if (t48 == 10'd524) begin t48 <= 10'd0; t48_tgl <= ~t48_tgl; end
        else t48 <= t48 + 10'd1;
    end
    reg [2:0] t48_s;
    always @(posedge clk) t48_s <= {t48_s[1:0], t48_tgl};
    wire tick48 = t48_s[2] ^ t48_s[1];

    // FM OPL2: una muestra cada CLK_HZ / 49716 ciclos (la frecuencia del chip)
    localparam OPL_DIV = (CLK_HZ + 24858) / 49716;
    reg [11:0] opl_cnt = 12'd0;
    reg        opl_tick = 1'b0;
    always @(posedge clk) begin
        opl_tick <= (opl_cnt == 12'd0);
        opl_cnt  <= (opl_cnt == OPL_DIV - 1) ? 12'd0 : opl_cnt + 12'd1;
    end
    wire signed [15:0] opl_smp;
    opl2 u_opl (
        .clk(clk), .rst(rst), .sel(s_opl), .we(r_we), .a(r_a[10:0]), .wd(r_wd),
        .rd(rd_opl), .tick(opl_tick), .smp(opl_smp), .smp_valid()
    );

    wire        aud_ov;
    wire [15:0] aud_l, aud_r;
    audio u_aud (
        .clk(clk), .rst(rst), .sel(s_aud), .we(r_we), .a(r_a[11:0]), .wd(r_wd),
        .rd(rd_aud), .irq(aud_irq), .tick48(tick48), .ext(opl_smp),
        .m_req(a_req), .m_addr(a_addr), .m_len(a_len), .m_ack(sd_ack[1]),
        .m_rdata(sd_rdata), .m_rvalid(sd_rvalid[1]),
        .out_valid(aud_ov), .out_l(aud_l), .out_r(aud_r)
    );

    // muestra -> dominio pix (dato estable durante ~20 us)
    reg [31:0] smp_h;
    reg        smp_tgl = 1'b0;
    always @(posedge clk) if (aud_ov) begin smp_h <= {aud_r, aud_l}; smp_tgl <= ~smp_tgl; end
    reg [2:0]  smp_s;
    reg        p_we;
    reg [31:0] p_smp;
    always @(posedge clk_pix) begin
        smp_s <= {smp_s[1:0], smp_tgl};
        p_we  <= smp_s[2] ^ smp_s[1];
        if (smp_s[2] ^ smp_s[1]) p_smp <= smp_h;
    end

    hdmi_tx u_hdmi (
        .clk_pix(clk_pix), .clk_ser(clk_ser), .rst(rst_pix), .hdmi_en(hdmi_mode),
        .rgb(rgb), .de(de), .hsync(hsync), .vsync(vsync), .hc(hc), .vc(vc),
        .aud_we(p_we), .aud_l(p_smp[15:0]), .aud_r(p_smp[31:16]),
        .tmds_clk_p(tmds_clk_p), .tmds_clk_n(tmds_clk_n),
        .tmds_d_p(tmds_d_p), .tmds_d_n(tmds_d_n), .tmds_word()
    );

    i2s_tx u_i2s (
        .clk(clk_pix), .rst(rst_pix), .frame(p_we), .l(p_smp[15:0]), .r(p_smp[31:16]),
        .bclk(i2s_bclk), .lrck(i2s_lrck), .sdata(i2s_data)
    );

    // ------------------------------------------------------------------ SD, mandos, PS/2
    wire sd_cs_n;
    sdspi u_sdc (
        .clk(clk), .rst(rst), .sel(s_sd), .we(r_we), .a(r_a[9:0]), .wd(r_wd), .rd(rd_sd),
        .sd_clk(sd_clk), .sd_mosi(sd_cmd), .sd_miso(sd_dat0), .sd_cs_n(sd_cs_n)
    );
    assign sd_dat3 = sd_cs_n;

    gamepad #(.CLK_HZ(CLK_HZ)) u_pad (
        .clk(clk), .rst(rst), .a(r_a[3:0]), .rd(rd_pad),
        .pad_latch(pad_latch), .pad_clk(pad_clk), .pad_data(pad_data)
    );

    ps2kbd u_ps2 (
        .clk(clk), .rst(rst), .sel(s_ps2), .we(r_we), .a(r_a[3:0]), .rd(rd_ps2),
        .irq(ps2_irq), .ps2_clk(ps2_clk), .ps2_data(ps2_data)
    );
endmodule
`default_nettype wire
