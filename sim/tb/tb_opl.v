// ============================================================================
// tb_opl.v - opl2 dirigido por fichero
//   +ev=<f>   líneas "<n_muestra> <off_hex> <dato_hex>": escritura antes de
//             calcular la muestra n (con el motor en reposo)
//   +n=<N>    muestras a generar ; +out=<f> una muestra (hex 16 bits) por línea
// ============================================================================
`timescale 1ns/1ps
module tb_opl;
    reg clk = 0;
    always #5 clk = ~clk;
    reg rst = 1;
    reg         sel = 0, we = 0;
    reg  [10:0] a = 0;
    reg  [31:0] wd = 0;
    wire [31:0] rd;
    reg         tick = 0;
    wire signed [15:0] smp;
    wire        sv;

    opl2 u_opl (
        .clk(clk), .rst(rst), .sel(sel), .we(we), .a(a), .wd(wd), .rd(rd),
        .tick(tick), .smp(smp), .smp_valid(sv)
    );

    task wr(input [10:0] off, input [31:0] d);
        begin
            @(posedge clk); sel <= 1; we <= 1; a <= off; wd <= d;
            @(posedge clk); sel <= 0; we <= 0;
        end
    endtask

    reg [8*256-1:0] fev, fout;
    integer fd, fo, r, ns, off, dat, n = 100, k, maxc = 0, c0;
    reg have;
    initial begin
        if (!$value$plusargs("ev=%s", fev)) fev = "opl_ev.txt";
        if (!$value$plusargs("out=%s", fout)) fout = "opl_out.txt";
        if ($value$plusargs("n=%d", n)) ;
        repeat (5) @(posedge clk);
        rst <= 0;
        wait (u_opl.st == 5'd1);
        fd = $fopen(fev, "r");
        fo = $fopen(fout, "w");
        r = $fscanf(fd, "%d %h %h\n", ns, off, dat);
        have = (r == 3);
        for (k = 0; k < n; k = k + 1) begin
            while (have && ns <= k) begin
                wr(off[10:0], dat);
                r = $fscanf(fd, "%d %h %h\n", ns, off, dat);
                have = (r == 3);
            end
            @(posedge clk); tick <= 1;
            @(posedge clk); tick <= 0;
            c0 = $time;
            @(posedge sv);
            if (($time - c0) / 10 > maxc) maxc = ($time - c0) / 10;
            @(negedge clk);
            $fwrite(fo, "%04h\n", smp);
        end
        $fclose(fo);
        $display("OPL: %0d muestras, máx %0d ciclos/muestra", n, maxc);
        $finish;
    end
endmodule
