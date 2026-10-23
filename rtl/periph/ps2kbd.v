// ============================================================================
// ps2kbd.v - Receptor PS/2 (teclado), FIFO de 16 códigos
//   +0x00 DATA R: [7:0] código, [8] válido (leer lo consume)
//   +0x04 STAT R: [0] hay datos, [1] error de paridad/trama (se borra al leer)
//   irq = hay datos
//   Nota: el teclado funciona a 5 V; hace falta adaptación de nivel
//   (o resistencias serie + pull-ups a 3,3 V).
// ============================================================================
`default_nettype none
module ps2kbd (
    input  wire        clk,
    input  wire        rst,
    input  wire        sel,
    input  wire        we,
    input  wire [3:0]  a,
    output reg  [31:0] rd,
    output wire        irq,
    input  wire        ps2_clk,
    input  wire        ps2_data
);
    reg [3:0] cs;
    reg [2:0] ds;
    always @(posedge clk) begin cs <= {cs[2:0], ps2_clk}; ds <= {ds[1:0], ps2_data}; end
    wire fall = (cs[3:1] == 3'b110);            // flanco de bajada filtrado

    reg [9:0]  sh;                              // start, 8 datos, paridad
    reg [3:0]  n;
    reg [15:0] tmo;
    reg [7:0]  f [0:15];
    reg [3:0]  wp, rp;
    reg [4:0]  cnt;
    reg        err;
    wire       pop  = sel & ~we & (a[3:2] == 2'd0) & (cnt != 5'd0);
    // trama completa: sh = {paridad, d7..d0, start}, bit actual = stop
    wire       good = (sh[0] == 1'b0) && ds[2] && (^sh[9:1]) && (cnt != 5'd16);
    wire       push = fall && (n == 4'd10) && good;
    assign irq = cnt != 5'd0;

    always @(posedge clk) begin
        if (rst) begin
            n <= 4'd0; wp <= 4'd0; rp <= 4'd0; cnt <= 5'd0; err <= 1'b0; tmo <= 16'd0;
        end else begin
            if (n != 4'd0) tmo <= tmo + 16'd1;
            if (tmo == 16'hFFFF) begin n <= 4'd0; tmo <= 16'd0; end
            if (fall) begin
                tmo <= 16'd0;
                if (n == 4'd10) begin
                    n <= 4'd0;
                    if (good) begin
                        f[wp] <= sh[8:1];
                        wp <= wp + 4'd1;
                    end else
                        err <= 1'b1;
                end else begin
                    sh <= {ds[2], sh[9:1]};
                    n  <= n + 4'd1;
                end
            end
            if (pop) rp <= rp + 4'd1;
            cnt <= cnt + (push ? 5'd1 : 5'd0) - (pop ? 5'd1 : 5'd0);
            if (sel && !we && a[3:2] == 2'd1) err <= 1'b0;
        end
        case (a[3:2])
        2'd0:    rd <= {23'd0, cnt != 5'd0, f[rp]};
        default: rd <= {30'd0, err, cnt != 5'd0};
        endcase
    end
endmodule
`default_nettype wire
