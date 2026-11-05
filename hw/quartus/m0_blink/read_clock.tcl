# Usage: quartus_stp -t hw/quartus/m0_blink/read_clock.tcl
# Measures CLOCK_50 against the host clock by reading the Gray-coded counter over JTAG.
# The host timer limits accuracy, so this is a check that the clock runs near 50 MHz.

proc gray_to_bin {hex} {
    set g [expr {"0x$hex"}]
    set b 0
    while {$g != 0} { set b [expr {$b ^ $g}]; set g [expr {$g >> 1}] }
    return $b
}

set hw [lindex [get_hardware_names] 0]
set dev ""
foreach d [get_device_names -hardware_name $hw] {
    if {[string match "*5CSE*" $d]} { set dev $d }
}
puts "hardware: $hw"
puts "device: $dev"

start_insystem_source_probe -hardware_name $hw -device_name $dev
set t0 [clock milliseconds]
set c0 [gray_to_bin [read_probe_data -instance_index 0 -value_in_hex]]
set prev $c0
set wraps 0
for {set i 1} {$i <= 5} {incr i} {
    after 2000
    set c [gray_to_bin [read_probe_data -instance_index 0 -value_in_hex]]
    set t [clock milliseconds]
    if {$c < $prev} { incr wraps }
    set prev $c
    set delta [expr {$c + $wraps * (1 << 32) - $c0}]
    puts [format "sample %d: count %u, elapsed %d ms, %.4f MHz" $i $c [expr {$t - $t0}] [expr {double($delta) / ($t - $t0) / 1000.0}]]
}
end_insystem_source_probe
