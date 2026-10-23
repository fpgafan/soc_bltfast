`timescale 1ns/1ps
// ============================================================================
// clocks.v - Clock generation (Gowin rPLL)
//   Video PLL  : 27 MHz x 14 / 3 = 126 MHz (TMDS serial, DDR) ; /5 = 25.2 MHz
//   System PLL : 27 MHz x SYS_FB / SYS_ID (CPU, SDRAM, peripherals)
//                CLKOUTP = same clock with dynamic phase (PSDA, 22.5°/step)
//                -> SDRAM clock
// ============================================================================
`default_nettype none
module clocks #(
    parameter SYS_ID   = 3,             // input divider
    parameter SYS_FB   = 10,            // multiplier  -> 27*10/3 = 90 MHz
    parameter SYS_OD   = 8              // VCO divider (VCO = fsys * OD)
)(
    input  wire       clk_27m,
    input  wire [3:0] sd_phase,
    output wire       clk_sys,
    output wire       clk_sd,           // clock to the SDRAM (phase-shifted)
    output wire       clk_ser,          // 126 MHz
    output wire       clk_pix,          // 25.2 MHz
    output wire       locked
);
    wire lock_v, lock_s;
`ifdef SIM
    // simulation: ideal clocks (sys 90 MHz, pix 25.2 MHz, SDRAM with 2 ns delay)
    reg cs = 1'b0, cp = 1'b0, cx = 1'b0, csd = 1'b0;
    reg [7:0] lk = 8'd0;
    always #(1000.0 / 90.0 / 2.0)  cs = ~cs;
    always #(1000.0 / 25.2 / 2.0)  cp = ~cp;
    always #(1000.0 / 126.0 / 2.0) cx = ~cx;
    always @(cs) csd <= #(2.0) cs;
    always @(posedge cs) if (lk != 8'hFF) lk <= lk + 8'd1;
    assign clk_sys = cs; assign clk_pix = cp; assign clk_ser = cx; assign clk_sd = csd;
    assign locked = lk[7];
`else

    rPLL #(
        .FCLKIN("27"),
        .DYN_IDIV_SEL("false"), .IDIV_SEL(2),
        .DYN_FBDIV_SEL("false"), .FBDIV_SEL(13),
        .DYN_ODIV_SEL("false"), .ODIV_SEL(8),
        .PSDA_SEL("0000"), .DYN_DA_EN("false"), .DUTYDA_SEL("1000"),
        .CLKOUT_FT_DIR(1'b1), .CLKOUTP_FT_DIR(1'b1),
        .CLKOUT_DLY_STEP(0), .CLKOUTP_DLY_STEP(0),
        .CLKFB_SEL("internal"), .CLKOUT_BYPASS("false"),
        .CLKOUTP_BYPASS("false"), .CLKOUTD_BYPASS("false"),
        .DYN_SDIV_SEL(2), .CLKOUTD_SRC("CLKOUT"), .CLKOUTD3_SRC("CLKOUT"),
        .DEVICE("GW2AR-18C")
    ) u_pll_vid (
        .CLKOUT(clk_ser), .LOCK(lock_v), .CLKOUTP(), .CLKOUTD(), .CLKOUTD3(),
        .RESET(1'b0), .RESET_P(1'b0), .CLKIN(clk_27m), .CLKFB(1'b0),
        .FBDSEL(6'b0), .IDSEL(6'b0), .ODSEL(6'b0),
        .PSDA(4'b0), .DUTYDA(4'b0), .FDLY(4'b0)
    );

    CLKDIV #(.DIV_MODE("5"), .GSREN("false")) u_clkdiv (
        .CLKOUT(clk_pix), .HCLKIN(clk_ser), .RESETN(lock_v), .CALIB(1'b0)
    );

    rPLL #(
        .FCLKIN("27"),
        .DYN_IDIV_SEL("false"), .IDIV_SEL(SYS_ID - 1),
        .DYN_FBDIV_SEL("false"), .FBDIV_SEL(SYS_FB - 1),
        .DYN_ODIV_SEL("false"), .ODIV_SEL(SYS_OD),
        .PSDA_SEL("0000"), .DYN_DA_EN("true"), .DUTYDA_SEL("1000"),
        .CLKOUT_FT_DIR(1'b1), .CLKOUTP_FT_DIR(1'b1),
        .CLKOUT_DLY_STEP(0), .CLKOUTP_DLY_STEP(0),
        .CLKFB_SEL("internal"), .CLKOUT_BYPASS("false"),
        .CLKOUTP_BYPASS("false"), .CLKOUTD_BYPASS("false"),
        .DYN_SDIV_SEL(2), .CLKOUTD_SRC("CLKOUT"), .CLKOUTD3_SRC("CLKOUT"),
        .DEVICE("GW2AR-18C")
    ) u_pll_sys (
        .CLKOUT(clk_sys), .LOCK(lock_s), .CLKOUTP(clk_sd), .CLKOUTD(), .CLKOUTD3(),
        .RESET(1'b0), .RESET_P(1'b0), .CLKIN(clk_27m), .CLKFB(1'b0),
        .FBDSEL(6'b0), .IDSEL(6'b0), .ODSEL(6'b0),
        .PSDA(sd_phase), .DUTYDA(4'b1000), .FDLY(4'b0)
    );

    assign locked = lock_v & lock_s;
`endif
endmodule
`default_nettype wire
