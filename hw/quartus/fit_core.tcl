# Fits nnue_core alone on 5CSEMA5F31C6 to measure resources and Fmax for docs/reports/M3_resources.md.
# Every port except clk is a virtual pin, so this is NOT the DE1-SoC board top and produces nothing to program.
# Run from an empty directory: quartus_sh -t <repo>/hw/quartus/fit_core.tcl <repo>
load_package flow

set repo [lindex $argv 0]
project_new nnue_core_fit -overwrite

set_global_assignment -name FAMILY "Cyclone V"
set_global_assignment -name DEVICE 5CSEMA5F31C6
set_global_assignment -name TOP_LEVEL_ENTITY nnue_core
set_global_assignment -name SEARCH_PATH $repo/hw/rtl
foreach f {generated/nnue_spec_pkg.sv nnue_math_pkg.sv sdp_ram.sv nnue_core.sv} {
    set_global_assignment -name SYSTEMVERILOG_FILE $repo/hw/rtl/$f
}
set_global_assignment -name SDC_FILE $repo/hw/quartus/nnue_core.sdc
set_global_assignment -name OPTIMIZATION_MODE "HIGH PERFORMANCE EFFORT"
foreach port {rst csr_* m_* irq} {
    set_instance_assignment -name VIRTUAL_PIN ON -to $port
}
export_assignments

execute_flow -compile
project_close
