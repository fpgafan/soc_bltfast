// ============================================================================
// sysctl.v - Registros de sistema (base 0x8000_0000)
//   +0x00 ID        R  "BLT1"
//   +0x04 LED       RW [5:0] (1 = encendido)
//   +0x08 BTN       R  [1:0] = {S2, S1}, nivel de los pines
//   +0x0C CLK_HZ    R  frecuencia del reloj del sistema
//   +0x10 MTIME     RW 64 bits (+0x14 alta), cuenta ciclos
//   +0x18 MTIMECMP  RW 64 bits (+0x1C alta); MTIP = mtime >= mtimecmp
//   +0x20 MSIP      RW [0] interrupción software
//   +0x24 IRQ_PEND  R  fuentes pendientes; W: 1 borra las de flanco
//   +0x28 IRQ_EN    RW máscara -> MEIP = |(PEND & EN)
//   +0x2C SDRAM     RW [2:0] latencia de captura, [7:4] fase del reloj
//                       (pasos de 22,5°), [8] R = SDRAM lista
//   +0x30 RESET     W  0x5EB007 = reinicio del SoC
//   +0x34 SCRATCH   RW (sobrevive al reinicio software)
//   +0x38 MISC      RW [0] amplificador de audio de la placa (PA_EN), por defecto 1
//   Fuentes de interrupción (bit): ver soc_top.v (irq_lvl = nivel,
//   irq_edge = pulso que queda pendiente hasta borrarse).
// ============================================================================
`default_nettype none
module sysctl #(
    parameter CLK_HZ   = 100_000_000,
    parameter RD_LAT0  = 3'd2,
    parameter PHASE0   = 4'd0
)(
    input  wire        clk,
    input  wire        rst,
    input  wire        sel,
    input  wire        we,
    input  wire [5:0]  a,
    input  wire [31:0] wd,
    output reg  [31:0] rd,
    output reg  [5:0]  led,
    input  wire [1:0]  btn,
    input  wire [15:0] irq_lvl,
    input  wire [15:0] irq_edge,
    output reg         meip,
    output reg         mtip,
    output reg         msip,
    output reg  [2:0]  sd_rdlat,
    output reg  [3:0]  sd_phase,
    input  wire        sd_ready,
    output reg         soft_reset,
    output reg         pa_en
);
    reg [31:0] mt_l, mt_h;
    reg        mt_c;
    wire [63:0] mtime = {mt_h, mt_l};
    reg [63:0] mtimecmp;
    reg        cmp_h_gt, cmp_h_eq, cmp_l_ge;
    reg [15:0] pend_e, irq_en;
    reg [31:0] scratch = 32'd0;
    reg [1:0]  b_s0, b_s1;
    always @(posedge clk) begin b_s0 <= btn; b_s1 <= b_s0; end

    wire [15:0] pend = pend_e | irq_lvl;

    always @(posedge clk) begin
        soft_reset <= 1'b0;
        if (rst) begin
            led <= 6'd0;
            mt_l <= 32'd0; mt_h <= 32'd0; mt_c <= 1'b0;
            mtimecmp <= 64'hFFFF_FFFF_FFFF_FFFF;
            pend_e <= 16'd0; irq_en <= 16'd0;
            msip <= 1'b0; meip <= 1'b0; mtip <= 1'b0;
            sd_rdlat <= RD_LAT0;
            pa_en <= 1'b1;
            sd_phase <= PHASE0;
        end else begin
            mt_l <= mt_l + 32'd1;
            mt_c <= (mt_l == 32'hFFFF_FFFE);
            if (mt_c) mt_h <= mt_h + 32'd1;
            // comparación en dos etapas (un ciclo de retraso en MTIP)
            cmp_h_gt <= mt_h > mtimecmp[63:32];
            cmp_h_eq <= mt_h == mtimecmp[63:32];
            cmp_l_ge <= mt_l >= mtimecmp[31:0];
            mtip  <= cmp_h_gt | (cmp_h_eq & cmp_l_ge);
            meip  <= |(pend & irq_en);
            pend_e <= pend_e | irq_edge;
            if (sel & we) begin
                case (a[5:2])
                4'h1: led <= wd[5:0];
                4'h4: mt_l <= wd;
                4'h5: mt_h <= wd;
                4'h6: mtimecmp[31:0]  <= wd;
                4'h7: mtimecmp[63:32] <= wd;
                4'h8: msip <= wd[0];
                4'h9: pend_e <= (pend_e & ~wd[15:0]) | irq_edge;
                4'hA: irq_en <= wd[15:0];
                4'hB: begin sd_rdlat <= wd[2:0]; sd_phase <= wd[7:4]; end
                4'hC: if (wd == 32'h005E_B007) soft_reset <= 1'b1;
                4'hD: scratch <= wd;
                4'hE: pa_en <= wd[0];
                default: ;
                endcase
            end
        end
        case (a[5:2])
        4'h0: rd <= "BLT1";
        4'h1: rd <= {26'd0, led};
        4'h2: rd <= {30'd0, b_s1};                    // nivel de los pines (ver README)
        4'h3: rd <= CLK_HZ;
        4'h4: rd <= mtime[31:0];
        4'h5: rd <= mtime[63:32];
        4'h6: rd <= mtimecmp[31:0];
        4'h7: rd <= mtimecmp[63:32];
        4'h8: rd <= {31'd0, msip};
        4'h9: rd <= {16'd0, pend};
        4'hA: rd <= {16'd0, irq_en};
        4'hB: rd <= {23'd0, sd_ready, sd_phase, 1'b0, sd_rdlat};
        4'hD: rd <= scratch;
        4'hE: rd <= {31'd0, pa_en};
        default: rd <= 32'd0;
        endcase
    end
endmodule
`default_nettype wire
