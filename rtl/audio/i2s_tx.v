// ============================================================================
// i2s_tx.v - Salida I2S estéreo 16 bits a 48 kHz (dominio pix, 25,2 MHz)
//   Cada trama dura 525 ciclos de píxel = 64 periodos de BCLK (3,072 MHz de
//   media; los semiperiodos se reparten en 4 y 5 ciclos con Bresenham).
//   LRCK = 0: canal izquierdo; el MSB sale un BCLK después del cambio de
//   LRCK (formato I2S), 32 BCLK por canal. 'frame' inicia una trama con l/r.
// ============================================================================
`default_nettype none
module i2s_tx (
    input  wire        clk,
    input  wire        rst,
    input  wire        frame,
    input  wire [15:0] l,
    input  wire [15:0] r,
    output reg         bclk,
    output reg         lrck,
    output reg         sdata
);
    reg [9:0]  pos;
    reg [9:0]  acc;
    reg [6:0]  half;                    // semiperiodo de BCLK (0..127)
    reg [63:0] sh;
    wire [9:0] acc_n = acc + 10'd128;
    always @(posedge clk) begin
        if (rst) begin
            bclk <= 1'b0; lrck <= 1'b0; sdata <= 1'b0;
            half <= 7'd0; acc <= 10'd0; pos <= 10'd524;
        end else if (frame) begin
            pos  <= 10'd0;
            acc  <= 10'd0;
            half <= 7'd0;
            bclk <= 1'b0;
            lrck <= 1'b0;
            sdata <= 1'b0;                          // bit de retardo I2S
            sh   <= {l, 16'd0, r, 16'd0};
        end else if (pos != 10'd524) begin
            pos <= pos + 10'd1;
            if (acc_n >= 10'd525) begin
                acc  <= acc_n - 10'd525;
                half <= half + 7'd1;
                bclk <= ~bclk;
                if (bclk) begin
                    // flanco de bajada: el receptor muestrea en el de subida
                    // el bit periodo k (k = half/2 + 1) del canal en curso
                    sdata <= sh[63];
                    sh    <= {sh[62:0], 1'b0};
                    lrck  <= (half[6:1] >= 6'd31) && (half[6:1] != 6'd63);
                end
            end else
                acc <= acc_n;
        end
    end
endmodule
`default_nettype wire
