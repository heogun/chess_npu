# Usage: quartus_stp -t tools/hps_jtag_read.tcl [<addr> <words> <file> ...]
# Reads HPS state over JTAG, needing no SD card, UART or bitstream. Only debug-port setup registers
# are written. Nothing in the HPS is changed, and the CPU is not halted.
source [file join [file dirname [info script]] hps_dap.tcl]

dap_open
use_ahb

puts "--- system registers"
foreach {name addr} {
    sysmgr.siliconid1 0xFFD08000
    sysmgr.bootinfo   0xFFD08014
    sysmgr.romcode_initswstate 0xFFD080C8
    sysmgr.romcode_bootromswstate 0xFFD080D0
    rstmgr.stat       0xFFD05000
    rstmgr.mpumodrst  0xFFD05010
    rstmgr.permodrst  0xFFD05014
    rstmgr.brgmodrst  0xFFD0501C
    clkmgr.ctrl       0xFFD04000
    clkmgr.bypass     0xFFD04004
    clkmgr.mainvco    0xFFD04040
    uart0.lcr         0xFFC0200C
    uart0.lsr         0xFFC02014
    sdmmc.ctrl        0xFF704000
    sdmmc.clkena      0xFF704010
    sdmmc.cmd         0xFF70402C
    sdmmc.resp0       0xFF704030
    sdmmc.rintsts     0xFF704044
    sdmmc.status      0xFF704048
} {
    puts [format "%-30s %s  %s" $name $addr [mem_read $addr]]
}

puts "--- OCRAM start"
foreach off {0x00 0x04 0x40 0x44 0x48 0x4C 0x100} {
    puts [format "ocram+%-6s %s" $off [mem_read [expr {0xFFFF0000 + $off}]]]
}

puts "--- CPU program counter samples (DBGPCSR)"
use_apb
foreach {cpu base} {cpu0 0x80110000 cpu1 0x80112000} {
    puts [format "%s DSCR %s PRSR %s" $cpu [mem_read [expr {$base + 0x88}]] [mem_read [expr {$base + 0x314}]]]
    for {set i 0} {$i < 6} {incr i} {
        puts "  pc sample [mem_read [expr {$base + 0x84}]]"
    }
}

use_ahb
foreach {addr words file} $quartus(args) {
    set f [open $file w]
    fconfigure $f -translation binary
    set done 0
    for {set i 0} {$i < $words} {incr i} {
        set v [mem_read [expr {$addr + 4 * $i}]]
        if {$v eq "FAULT"} { puts "FAULT at word $i of $addr"; break }
        puts -nonewline $f [binary format i [expr {$v & 0xFFFFFFFF}]]
        incr done
    }
    close $f
    puts "dumped $done words from $addr to $file"
}

dap_close
