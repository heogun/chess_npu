# Usage: quartus_sh -t hw/quartus/board/project.tcl [probe|nnue]
# Creates build/board/quartus/board.qpf (probe, the default) or build/board/quartus_nnue/board.qpf
# (the SF19 NNUE core). Both use the same soc.qsys. build.ps1 runs the whole flow.
# Global settings and HPS I/O standards follow the Terasic reference DE1_SOC_Linux_FB.qsf.
# DDR3 pin settings come from the generated hps_sdram_p0_pin_assignments.tcl, not from here.

set here [file dirname [file normalize [info script]]]
set repo [file normalize "$here/../../.."]
set design [expr {[llength $argv] > 0 ? [lindex $argv 0] : "probe"}]
if {$design ni {probe nnue}} { error "design must be probe or nnue, got $design" }
set out [expr {$design eq "nnue" ? "$repo/build/board/quartus_nnue" : "$repo/build/board/quartus"}]
file mkdir $out
cd $out

project_new board -overwrite
set_global_assignment -name FAMILY "Cyclone V"
set_global_assignment -name DEVICE 5CSEMA5F31C6
set_global_assignment -name TOP_LEVEL_ENTITY board_top
set_global_assignment -name QIP_FILE "$repo/build/board/soc/synthesis/soc.qip"
if {$design eq "nnue"} {
    foreach f {generated/nnue_spec_pkg.sv nnue_math_pkg.sv sdp_ram.sv nnue_core.sv} {
        set_global_assignment -name SYSTEMVERILOG_FILE "$repo/hw/rtl/$f"
    }
    set_parameter -name USE_NNUE 1
    set_global_assignment -name OPTIMIZATION_MODE "HIGH PERFORMANCE EFFORT"
}
set_global_assignment -name SYSTEMVERILOG_FILE "$repo/hw/rtl/board/mem_probe.sv"
set_global_assignment -name SYSTEMVERILOG_FILE "$repo/hw/rtl/board/board_top.sv"
set_global_assignment -name SDC_FILE "$here/board.sdc"

# From the reference .qsf (UniPHY HPS SDRAM settings and timing options).
set_global_assignment -name UNIPHY_SEQUENCER_DQS_CONFIG_ENABLE ON
set_global_assignment -name OPTIMIZE_MULTI_CORNER_TIMING ON
set_global_assignment -name USE_DLL_FREQUENCY_FOR_DQS_DELAY_CHAIN ON
set_global_assignment -name ECO_REGENERATE_REPORT ON
set_global_assignment -name SYNTH_TIMING_DRIVEN_SYNTHESIS ON
set_global_assignment -name OPTIMIZE_HOLD_TIMING "ALL PATHS"
set_global_assignment -name CYCLONEII_RESERVE_NCEO_AFTER_CONFIGURATION "USE AS REGULAR IO"

set_location_assignment PIN_AF14 -to CLOCK_50
set i 0
foreach pin {V16 W16 V17 V18 W17 W19 Y19 W20 W21 Y21} {
    set_location_assignment PIN_$pin -to LEDR[$i]
    incr i
}
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to CLOCK_50
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to LEDR[*]

# HPS peripheral pins are dedicated, so no locations. I/O standard as in the reference.
foreach port {
    HPS_CONV_USB_N HPS_ENET_GTX_CLK HPS_ENET_INT_N HPS_ENET_MDC HPS_ENET_MDIO HPS_ENET_RX_CLK
    HPS_ENET_RX_DATA[*] HPS_ENET_RX_DV HPS_ENET_TX_DATA[*] HPS_ENET_TX_EN
    HPS_FLASH_DATA[*] HPS_FLASH_DCLK HPS_FLASH_NCSO HPS_GSENSOR_INT
    HPS_I2C1_SCLK HPS_I2C1_SDAT HPS_I2C2_SCLK HPS_I2C2_SDAT HPS_I2C_CONTROL
    HPS_KEY HPS_LED HPS_LTC_GPIO HPS_SD_CLK HPS_SD_CMD HPS_SD_DATA[*]
    HPS_SPIM_CLK HPS_SPIM_MISO HPS_SPIM_MOSI HPS_SPIM_SS HPS_UART_RX HPS_UART_TX
    HPS_USB_CLKOUT HPS_USB_DATA[*] HPS_USB_DIR HPS_USB_NXT HPS_USB_STP
} {
    set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to $port
}

project_close
