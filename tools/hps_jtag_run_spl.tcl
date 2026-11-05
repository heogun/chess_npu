# Usage: quartus_stp -t tools/hps_jtag_run_spl.tcl <u-boot-with-spl.sfp>
# Halts CPU0, loads the first SPL copy into OCRAM, and starts it at 0xFFFF0000. This skips the Boot
# ROM's SD read, so it separates Boot ROM problems from SPL and UART problems. It changes only
# volatile HPS state, and a power cycle undoes it. The SD card is not written.
source [file join [file dirname [info script]] hps_dap.tcl]

set DBG 0x80110000
set OCRAM 0xFFFF0000
set path [lindex $quartus(args) 0]

set f [open $path r]
fconfigure $f -translation binary
set blob [read $f 65536]
close $f
binary scan $blob @64iccs magic ver flags length
if {($magic & 0xFFFFFFFF) != 0x31305341} { error "no preloader header in $path" }
set words [expr {$length & 0xFFFF}]
puts "SPL image: $words words"

dap_open

# Halt CPU0.
use_apb
set dscr [mem_read [expr {$DBG + 0x88}]]
puts "DSCR before: $dscr, pc [mem_read [expr {$DBG + 0x84}]]"
mem_write [expr {$DBG + 0x88}] [expr {$dscr | (1 << 14)}]
mem_write [expr {$DBG + 0x90}] 1
for {set i 0} {$i < 100} {incr i} {
    set dscr [mem_read [expr {$DBG + 0x88}]]
    if {$dscr & 1} break
    after 10
}
if {!($dscr & 1)} { error "CPU0 did not halt, DSCR $dscr" }
puts "halted, DSCR $dscr"

# Load through the AHB-AP with address auto-increment. It wraps at 1 KB, so TAR is set per block.
use_ahb
ap_write 0x0 0x23000012
binary scan $blob i$words data
set i 0
foreach w $data {
    if {$i % 256 == 0} { ap_write 0x4 [expr {$OCRAM + 4 * $i}] }
    ap_write 0xC [expr {$w & 0xFFFFFFFF}]
    incr i
    if {$i % 4096 == 0} { puts "  loaded $i words" }
}
set st [dp_read 0x4]
if {$st & 0x20} { error "bus fault during load" }

# Check by reading back.
ap_write 0x0 0x23000002
set bad 0
foreach idx [list 0 1 2 3 16 17 18 19 256 1024 4096 [expr {$words / 2}] [expr {$words - 2}] [expr {$words - 1}]] {
    set want [expr {[lindex $data $idx] & 0xFFFFFFFF}]
    set got [mem_read [expr {$OCRAM + 4 * $idx}]]
    if {$got eq "FAULT" || $got != $want} {
        puts [format "  mismatch word %d: got %s want 0x%08X" $idx $got $want]
        incr bad
    }
}
if {$bad} { error "OCRAM read-back failed" }
puts "OCRAM read-back matches at the sampled words"

# Set PC through the instruction transfer register, then restart.
use_apb
proc wait_instr {DBG} {
    for {set i 0} {$i < 100} {incr i} {
        if {[mem_read [expr {$DBG + 0x88}]] & (1 << 24)} return
        after 1
    }
    error "instruction did not complete"
}
set dscr [mem_read [expr {$DBG + 0x88}]]
mem_write [expr {$DBG + 0x88}] [expr {$dscr | (1 << 13)}]
mem_write [expr {$DBG + 0x80}] $OCRAM
mem_write [expr {$DBG + 0x84}] 0xEE100E15 ;# mrc p14, 0, r0, c0, c5, 0 reads DTRRX into r0
wait_instr $DBG
mem_write [expr {$DBG + 0x84}] 0xE1A0F000 ;# mov pc, r0
wait_instr $DBG
mem_write [expr {$DBG + 0x84}] 0xE1A0000F ;# mov r0, pc
wait_instr $DBG
mem_write [expr {$DBG + 0x84}] 0xEE000E15 ;# mcr p14, 0, r0, c0, c5, 0
wait_instr $DBG
puts "pc after write (reads as pc + 8 in debug state): [mem_read [expr {$DBG + 0x8C}]]"
puts "DSCR before restart: [mem_read [expr {$DBG + 0x88}]]"

# Further arguments are checkpoints, as name=address. Only one hardware breakpoint is armed at a
# time, and the next one is armed once it hits. SPL runs in Thumb state, so no instructions are
# injected after this point: the debug transfer path here only encodes ARM instructions.
proc restart {DBG keep_debug} {
    set dscr [mem_read [expr {$DBG + 0x88}]]
    set clear [expr {$keep_debug ? (1 << 13) : ((1 << 13) | (1 << 14))}]
    mem_write [expr {$DBG + 0x88}] [expr {$dscr & ~$clear}]
    mem_write [expr {$DBG + 0x90}] 6 ;# clear sticky exceptions, restart
}

proc samples {DBG} {
    set out {}
    for {set i 0} {$i < 8} {incr i} { lappend out [mem_read [expr {$DBG + 0x84}]]; after 50 }
    return $out
}

set checkpoints [lrange $quartus(args) 1 end]
foreach cp $checkpoints {
    lassign [split $cp =] name a
    mem_write [expr {$DBG + 0x100}] [expr {$a & ~3}]
    mem_write [expr {$DBG + 0x140}] 0x1E7
    restart $DBG 1
    set dscr 0
    for {set i 0} {$i < 300} {incr i} {
        set dscr [mem_read [expr {$DBG + 0x88}]]
        if {$dscr ne "FAULT" && ($dscr & 1)} break
        after 10
    }
    if {$dscr eq "FAULT" || !($dscr & 1)} {
        puts "NOT REACHED: $name ($a), DSCR $dscr, pc samples [samples $DBG]"
        break
    }
    puts "reached $name ($a)"
    mem_write [expr {$DBG + 0x140}] 0
}
if {[mem_read [expr {$DBG + 0x88}]] & 1} {
    # Stopped at the last checkpoint: the controller state can be read over the AHB-AP.
    use_ahb
    puts "--- SD controller, CPU stopped at the last checkpoint"
    foreach {name off} {ctrl 0x00 pwren 0x04 clkdiv 0x08 clkena 0x10 tmout 0x14 ctype 0x18 blksiz 0x1C
                        bytcnt 0x20 intmask 0x24 cmdarg 0x28 cmd 0x2C resp0 0x30 resp1 0x34 mintsts 0x40
                        rintsts 0x44 status 0x48 fifoth 0x4C cdetect 0x50 wrtprt 0x54 tcbcnt 0x5C tbbcnt 0x60} {
        puts [format "sdmmc.%-8s %s" $name [mem_read [expr {0xFF704000 + $off}]]]
    }
    puts "clkmgr.perpll.en      [mem_read 0xFFD040A0]"
    puts "clkmgr.perpll.src     [mem_read 0xFFD040AC]"
    puts "clkmgr.perpll.vco     [mem_read 0xFFD04080]"
    puts "sysmgr.sdmmcgrp.ctrl  [mem_read 0xFFD08108]"
    use_apb
    restart $DBG 0
}
puts "running, pc samples [samples $DBG]"

dap_close
