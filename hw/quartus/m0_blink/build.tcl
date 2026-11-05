# Usage: quartus_sh -t hw/quartus/m0_blink/build.tcl
# Outputs go to build/m0_blink, which is ignored by git.
load_package flow

set here [file dirname [file normalize [info script]]]
set repo [file normalize "$here/../../.."]
set out "$repo/build/m0_blink"
file mkdir $out
cd $out

project_new m0_blink -overwrite
set_global_assignment -name FAMILY "Cyclone V"
set_global_assignment -name DEVICE 5CSEMA5F31C6
set_global_assignment -name TOP_LEVEL_ENTITY m0_blink
set_global_assignment -name SYSTEMVERILOG_FILE "$here/m0_blink.sv"
set_global_assignment -name SDC_FILE "$here/m0_blink.sdc"
set_global_assignment -name STRATIX_DEVICE_IO_STANDARD "3.3-V LVTTL"

set_location_assignment PIN_AF14 -to CLOCK_50
set i 0
foreach pin {V16 W16 V17 V18 W17 W19 Y19 W20 W21 Y21} {
    set_location_assignment PIN_$pin -to LEDR[$i]
    incr i
}
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to CLOCK_50
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to LEDR[*]

execute_flow -compile
project_close
