# HPS SDRAM and HPS I/O constraints come from the .sdc files in the generated soc.qip.
create_clock -name CLOCK_50 -period 20.000 [get_ports CLOCK_50]
derive_pll_clocks
derive_clock_uncertainty
set_false_path -to [get_ports LEDR[*]]
