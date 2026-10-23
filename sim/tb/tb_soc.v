// ============================================================================
// tb_soc.v - SoC completo (soc_top con relojes de simulación) + modelo de SDRAM
//   Imprime lo que sale por la UART. Con +load=<fichero> (bytes en hex, uno por
//   línea) los envía por la UART cuando la ROM anuncia "RVBOOT".
//   +baud=<n> (115200 por defecto) ; +maxms=<n> tiempo máximo simulado
// ============================================================================
`timescale 1ns/1ps
module tb_soc;
    wire        tx;
    reg         rx = 1'b1;
    wire [5:0]  led_n;
    wire        sd_clk, sd_cmd, sd_dat3;
    wire        O_sdram_clk, O_sdram_cke, O_sdram_cs_n, O_sdram_cas_n, O_sdram_ras_n, O_sdram_wen_n;
    wire [3:0]  O_sdram_dqm;
    wire [10:0] O_sdram_addr;
    wire [1:0]  O_sdram_ba;
    wire [31:0] IO_sdram_dq;

    soc_top #(.ROM_FILE("../../sw/build/boot.hex")) dut (
        .clk_27m(1'b0), .btn(2'b00), .led_n(led_n), .uart_tx(tx), .uart_rx(rx),
        .tmds_clk_p(), .tmds_clk_n(), .tmds_d_p(), .tmds_d_n(),
        .i2s_bclk(), .i2s_lrck(), .i2s_data(), .pa_en(),
        .sd_clk(sd_clk), .sd_cmd(sd_cmd), .sd_dat0(1'b1), .sd_dat3(sd_dat3),
        .pad_latch(), .pad_clk(), .pad_data(2'b11),
        .ps2_clk(1'b1), .ps2_data(1'b1),
        .O_sdram_clk(O_sdram_clk), .O_sdram_cke(O_sdram_cke), .O_sdram_cs_n(O_sdram_cs_n),
        .O_sdram_cas_n(O_sdram_cas_n), .O_sdram_ras_n(O_sdram_ras_n), .O_sdram_wen_n(O_sdram_wen_n),
        .O_sdram_dqm(O_sdram_dqm), .O_sdram_addr(O_sdram_addr), .O_sdram_ba(O_sdram_ba),
        .IO_sdram_dq(IO_sdram_dq)
    );
    sdram_model u_mem (
        .clk(O_sdram_clk), .cke(O_sdram_cke), .cs_n(O_sdram_cs_n), .ras_n(O_sdram_ras_n),
        .cas_n(O_sdram_cas_n), .we_n(O_sdram_wen_n), .ba(O_sdram_ba), .a(O_sdram_addr),
        .dqm(O_sdram_dqm), .dq(IO_sdram_dq)
    );

    // ---------------------------------------------------------------- UART
    real    bit_ns;
    integer baud = 115200;
    reg [8*64-1:0] line = 0;
    reg [7:0] ch;
    integer k;
    reg seen_boot = 0;
    initial begin
        if ($value$plusargs("baud=%d", baud)) ;
        bit_ns = 1.0e9 / baud;
    end
    // receptor (salida del SoC)
    always @(negedge tx) begin
        #(bit_ns * 1.5);
        for (k = 0; k < 8; k = k + 1) begin ch[k] = tx; #(bit_ns); end
        if (ch == 8'h0A) begin
            if (line[8*6-1:0] == "RVBOOT") seen_boot = 1;
            line = 0;
        end else if (ch != 8'h0D)
            line = {line[8*63-1:0], ch};
        $write("%c", ch);
    end
    // emisor (entrada del SoC)
    task send(input [7:0] b);
        integer j;
        begin
            rx = 0; #(bit_ns);
            for (j = 0; j < 8; j = j + 1) begin rx = b[j]; #(bit_ns); end
            rx = 1; #(bit_ns);
        end
    endtask

    reg [8*256-1:0] fload;
    reg [7:0] lbuf [0:262143];
    integer nload = 0, fd, r, v, maxms = 200;
    initial begin
        if ($value$plusargs("maxms=%d", maxms)) ;
        if ($value$plusargs("load=%s", fload)) begin
            fd = $fopen(fload, "r");
            while (!$feof(fd)) begin
                r = $fscanf(fd, "%h\n", v);
                if (r == 1) begin lbuf[nload] = v; nload = nload + 1; end
            end
            $fclose(fd);
            wait (seen_boot);
            #20000;
            $display("\n[tb] enviando %0d bytes", nload);
            for (k = 0; k < nload; k = k + 1) send(lbuf[k]);
            $display("[tb] enviado");
        end
    end
    initial begin
        #(maxms * 1000000.0);
        $display("\n[tb] fin de tiempo (%0d ms), LEDs=%b, errores SDRAM=%0d", maxms, ~led_n, u_mem.errors);
        $finish;
    end
    // fin pedido por el programa: escribir 0x5EB007 en SYS_SCRATCH+... (usamos un LED patrón)
    always @(led_n) if (~led_n == 6'b101010) begin
        #1000;
        $display("\n[tb] el programa terminó (LEDs=101010), errores SDRAM=%0d", u_mem.errors);
        $finish;
    end
endmodule
