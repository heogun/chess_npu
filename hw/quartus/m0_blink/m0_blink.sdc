create_clock -name CLOCK_50 -period 20.000 [get_ports CLOCK_50]
derive_clock_uncertainty
set_false_path -to [get_ports LEDR[*]]
