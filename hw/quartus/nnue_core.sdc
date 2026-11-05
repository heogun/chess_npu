# 100 MHz is the initial target from docs/ARCHITECTURE.md, not a verified result.
create_clock -name clk -period 10.000 [get_ports clk]
derive_clock_uncertainty
