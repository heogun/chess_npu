# ARM ADIv5 JTAG-DP access to the Cyclone V HPS through Quartus low-level JTAG. Source this file.
package require ::quartus::jtag

set IR_DPACC 0xA
set IR_APACC 0xB
set AHB_AP 0
set APB_AP 1
set cur_ir -1

proc hex9 {v} { return [format %09llX $v] }

# One 35-bit transaction. Returns {ack data} of the previous transaction's result.
proc shift {ir addr rnw data} {
    global cur_ir
    if {$cur_ir != $ir} {
        device_ir_shift -ir_value $ir -no_captured_ir_value
        set cur_ir $ir
    }
    set req [expr {(wide($data) << 3) | (($addr >> 2) << 1) | $rnw}]
    set out [device_dr_shift -length 35 -dr_value [hex9 $req] -value_in_hex]
    set v [expr {wide("0x$out")}]
    return [list [expr {$v & 7}] [expr {($v >> 3) & 0xFFFFFFFF}]]
}

# Retries on WAIT (ack 1). An ack of 2 means OK or FAULT, which CTRL/STAT tells apart.
proc xact {ir addr rnw data} {
    for {set i 0} {$i < 200} {incr i} {
        lassign [shift $ir $addr $rnw $data] ack val
        if {$ack != 1} { return $val }
    }
    error "DAP stuck in WAIT"
}

proc dp_write {addr v} { global IR_DPACC; xact $IR_DPACC $addr 0 $v }
proc dp_read {addr} {
    global IR_DPACC
    xact $IR_DPACC $addr 1 0
    return [xact $IR_DPACC 0xC 1 0]
}
proc ap_write {addr v} { global IR_APACC; xact $IR_APACC $addr 0 $v }
proc ap_read {addr} {
    global IR_APACC IR_DPACC
    xact $IR_APACC $addr 1 0
    return [xact $IR_DPACC 0xC 1 0]
}

# On a JTAG-DP the sticky flags are cleared by writing ones to them in CTRL/STAT, not through ABORT.
proc clear_errors {} {
    dp_write 0x4 [expr {0x50000000 | 0x32}]
}

proc use_ahb {} {
    global AHB_AP
    clear_errors
    dp_write 0x8 [expr {$AHB_AP << 24}]
    ap_write 0x0 0x23000002
}

proc use_apb {} {
    global APB_AP
    clear_errors
    dp_write 0x8 [expr {$APB_AP << 24}]
    ap_write 0x0 0x80000002
}

# Returns the word, or "FAULT" if the bus access failed, e.g. a peripheral held in reset.
proc mem_read {addr} {
    ap_write 0x4 $addr
    set v [ap_read 0xC]
    set st [dp_read 0x4]
    if {$st & 0x20} {
        clear_errors
        return FAULT
    }
    return [format 0x%08X $v]
}

proc mem_write {addr v} {
    ap_write 0x4 $addr
    ap_write 0xC $v
    set st [dp_read 0x4]
    if {$st & 0x20} {
        clear_errors
        error [format "write fault at 0x%08X" $addr]
    }
}

proc dap_open {} {
    set hw [lindex [get_hardware_names] 0]
    set dev ""
    foreach d [get_device_names -hardware_name $hw] {
        if {[string match "*SOCVHPS*" $d]} { set dev $d }
    }
    puts "hardware: $hw"
    puts "device: $dev"
    open_device -hardware_name $hw -device_name $dev
    device_lock -timeout 10000
    clear_errors
    after 50
    set st [dp_read 0x4]
    puts [format "CTRL/STAT: 0x%08X (debug power ack %d, system power ack %d)" $st [expr {($st >> 29) & 1}] [expr {($st >> 31) & 1}]]
}

proc dap_close {} {
    device_unlock
    close_device
}
