// 27 MHz input clock
create_clock -name clk_27m -period 37.037 -waveform {0 18.518} [get_ports {clk_27m}]
// System PLL: 27 * 10 / 3 = 90 MHz (CPU, SDRAM, peripherals).
// Deliberately constrained to 99 MHz (27 * 11 / 3): ~10 % margin. At a real
// 99 MHz the decode -> forwarding -> ic_en path was left with 2 ps
// of slack and the CPU failed with the SDRAM busy (video/blitter) in Doom.
create_generated_clock -name clk_sys -source [get_ports {clk_27m}] -master_clock clk_27m -multiply_by 11 -divide_by 3 [get_pins {u_clk/u_pll_sys/CLKOUT}]
// Video PLL: 27 * 14 / 3 = 126 MHz (TMDS serial) ; /5 = 25.2 MHz (pixel)
create_generated_clock -name clk_ser -source [get_ports {clk_27m}] -master_clock clk_27m -multiply_by 14 -divide_by 3 [get_pins {u_clk/u_pll_vid/CLKOUT}]
create_generated_clock -name clk_pix -source [get_pins {u_clk/u_pll_vid/CLKOUT}] -master_clock clk_ser -divide_by 5 [get_pins {u_clk/u_clkdiv/CLKOUT}]
// sys <-> pix crossings go through synchronizers (toggles with stable data)
// and dual-clock memories (line buffer, palette)
set_clock_groups -asynchronous -group [get_clocks {clk_sys}] -group [get_clocks {clk_pix clk_ser}]
