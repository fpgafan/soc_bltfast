# Síntesis + PnR con Gowin EDA:  gw_sh build.tcl   (desde la raíz del proyecto)
set_device -name GW2AR-18C GW2AR-LV18QN88C8/I7
foreach f [glob rtl/*.v rtl/cpu/*.v rtl/mem/*.v rtl/periph/*.v rtl/video/*.v rtl/audio/*.v] { add_file $f }
add_file constraints/tang20k.cst
add_file constraints/tang20k.sdc
set_option -top_module soc_top
set_option -output_base_name bltfast
set_option -verilog_std v2001
set_option -use_mspi_as_gpio 1
set_option -use_sspi_as_gpio 1
set_option -timing_driven 1
set_option -place_option 1
set_option -route_option 1
set_option -ireg_in_iob 1
set_option -oreg_in_iob 1
set_option -ioreg_in_iob 1
run all
