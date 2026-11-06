# Usage: qsys-script --script=hw/quartus/board/soc.tcl   (run from hw/quartus/board)
# HPS with an Avalon-MM FPGA-to-SDRAM port and the lightweight HPS-to-FPGA bridge for CSRs.
# The port is 64-bit (soc.qsys) unless width is set to 128 first (w128/soc.qsys); build.ps1 does that.
# HPS pins, clocks and memory come from hps_params.tcl. Fabric interfaces are set here.
package require -exact qsys 18.0

source hps_params.tcl
create_system soc
set_project_property DEVICE_FAMILY {Cyclone V}
set_project_property DEVICE 5CSEMA5F31C6

add_instance clk_0 clock_source
set_instance_parameter_value clk_0 clockFrequency 50000000
set_instance_parameter_value clk_0 clockFrequencyKnown true
set_instance_parameter_value clk_0 resetSynchronousEdges NONE

add_instance pll_0 altera_pll
set_instance_parameter_value pll_0 gui_reference_clock_frequency 50.0
set_instance_parameter_value pll_0 gui_use_locked true
set_instance_parameter_value pll_0 gui_number_of_clocks 1
set_instance_parameter_value pll_0 gui_output_clock_frequency0 100.0

add_instance hps_0 altera_hps
set failed {}
foreach {name value} $hps_params {
    # List parameters are stored comma-separated.
    if {[lsearch -exact {GPIO_Enable LOANIO_Enable} $name] >= 0} { set value [split $value ,] }
    if {[catch {set_instance_parameter_value hps_0 $name $value} err]} { lappend failed $name }
}
puts "HPS parameters not applied: $failed"
set_instance_parameter_value hps_0 BOOTFROMFPGA_Enable false
set_instance_parameter_value hps_0 F2SINTERRUPT_Enable false
set_instance_parameter_value hps_0 F2S_Width 0
set_instance_parameter_value hps_0 S2F_Width 0
set_instance_parameter_value hps_0 LWH2F_Enable true
set_instance_parameter_value hps_0 F2SDRAM_Type {{Avalon-MM Bidirectional}}
# build.ps1 passes the width as --cmd="set width 128"; qsys-script does not see the environment.
if {![info exists width]} { set width 64 }
if {[lsearch -exact {64 128} $width] < 0} { error "F2SDRAM width must be 64 or 128, got $width" }
set_instance_parameter_value hps_0 F2SDRAM_Width $width

add_instance csr_bridge altera_avalon_mm_bridge
set_instance_parameter_value csr_bridge DATA_WIDTH 32
set_instance_parameter_value csr_bridge SYMBOL_WIDTH 8
set_instance_parameter_value csr_bridge ADDRESS_WIDTH 12
set_instance_parameter_value csr_bridge ADDRESS_UNITS SYMBOLS
set_instance_parameter_value csr_bridge MAX_BURST_SIZE 1
set_instance_parameter_value csr_bridge MAX_PENDING_RESPONSES 1

add_connection clk_0.clk pll_0.refclk
add_connection clk_0.clk_reset pll_0.reset
add_connection pll_0.outclk0 csr_bridge.clk
add_connection pll_0.outclk0 hps_0.h2f_lw_axi_clock
add_connection pll_0.outclk0 hps_0.f2h_sdram0_clock
add_connection clk_0.clk_reset csr_bridge.reset
add_connection hps_0.h2f_reset csr_bridge.reset
add_connection hps_0.h2f_lw_axi_master csr_bridge.s0
set_connection_parameter_value hps_0.h2f_lw_axi_master/csr_bridge.s0 baseAddress 0x0

add_interface clk clock sink
set_interface_property clk EXPORT_OF clk_0.clk_in
add_interface reset reset sink
set_interface_property reset EXPORT_OF clk_0.clk_in_reset
add_interface clk_100 clock source
set_interface_property clk_100 EXPORT_OF pll_0.outclk0
add_interface pll_locked conduit end
set_interface_property pll_locked EXPORT_OF pll_0.locked
add_interface hps_reset reset source
set_interface_property hps_reset EXPORT_OF hps_0.h2f_reset
add_interface memory conduit end
set_interface_property memory EXPORT_OF hps_0.memory
add_interface hps_io conduit end
set_interface_property hps_io EXPORT_OF hps_0.hps_io
add_interface csr avalon master
set_interface_property csr EXPORT_OF csr_bridge.m0
add_interface sdram avalon slave
set_interface_property sdram EXPORT_OF hps_0.f2h_sdram0_data

# The system name follows the file name, so other widths keep soc.qsys in their own folder.
if {$width == 64} {
    save_system soc.qsys
} else {
    file mkdir w$width
    save_system w$width/soc.qsys
}
