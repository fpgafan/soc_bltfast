// Reloj de entrada 27 MHz
create_clock -name clk_27m -period 37.037 -waveform {0 18.518} [get_ports {clk_27m}]
// PLL del sistema: 27 * 10 / 3 = 90 MHz (CPU, SDRAM, periféricos).
// Se restringe a 99 MHz (27 * 11 / 3) a propósito: ~10 % de margen. A 99 MHz
// reales el camino decodificación -> adelantamiento -> ic_en quedaba con 2 ps
// de holgura y la CPU fallaba con la SDRAM ocupada (vídeo/blitter) en Doom.
create_generated_clock -name clk_sys -source [get_ports {clk_27m}] -master_clock clk_27m -multiply_by 11 -divide_by 3 [get_pins {u_clk/u_pll_sys/CLKOUT}]
// PLL de vídeo: 27 * 14 / 3 = 126 MHz (serie TMDS) ; /5 = 25,2 MHz (píxel)
create_generated_clock -name clk_ser -source [get_ports {clk_27m}] -master_clock clk_27m -multiply_by 14 -divide_by 3 [get_pins {u_clk/u_pll_vid/CLKOUT}]
create_generated_clock -name clk_pix -source [get_pins {u_clk/u_pll_vid/CLKOUT}] -master_clock clk_ser -divide_by 5 [get_pins {u_clk/u_clkdiv/CLKOUT}]
// Los cruces sys <-> pix van por sincronizadores (toggles con dato estable)
// y memorias de doble reloj (buffer de línea, paleta)
set_clock_groups -asynchronous -group [get_clocks {clk_sys}] -group [get_clocks {clk_pix clk_ser}]
