# Usage: quartus_stp -t tools/hps_jtag_cpu.tcl
# Briefly halts CPU0, prints its mode and exception registers, and resumes it.
source [file join [file dirname [info script]] hps_dap.tcl]

set DBG 0x80110000

proc wait_instr {} {
    global DBG
    for {set i 0} {$i < 100} {incr i} {
        if {[mem_read [expr {$DBG + 0x88}]] & (1 << 24)} return
        after 1
    }
    error "instruction did not complete"
}
proc exec_insn {op} {
    global DBG
    mem_write [expr {$DBG + 0x84}] $op
    wait_instr
}
# Runs an instruction that puts a value in r0, then copies r0 out through DTRTX.
proc get {op} {
    global DBG
    exec_insn $op
    exec_insn 0xEE000E15 ;# mcr p14, 0, r0, c0, c5, 0
    return [mem_read [expr {$DBG + 0x8C}]]
}

dap_open
use_apb
set dscr [mem_read [expr {$DBG + 0x88}]]
mem_write [expr {$DBG + 0x88}] [expr {$dscr | (1 << 14)}]
mem_write [expr {$DBG + 0x90}] 1
for {set i 0} {$i < 100} {incr i} {
    set dscr [mem_read [expr {$DBG + 0x88}]]
    if {$dscr & 1} break
    after 10
}
if {!($dscr & 1)} { error "CPU0 did not halt, DSCR $dscr" }
puts "halted, DSCR $dscr"
mem_write [expr {$DBG + 0x88}] [expr {$dscr | (1 << 13)}]

# r0 is saved and restored, so the resumed code is unaffected.
exec_insn 0xEE000E15
set saved_r0 [mem_read [expr {$DBG + 0x8C}]]
puts "r0     $saved_r0"
foreach {name op} {
    cpsr  0xE10F0000
    pc    0xE1A0000F
    lr    0xE1A0000E
    sp    0xE1A0000D
    spsr  0xE14F0000
    sctlr 0xEE110F10
    vbar  0xEE1C0F10
    dfsr  0xEE150F10
    dfar  0xEE160F10
    ifsr  0xEE150F30
    ifar  0xEE160F50
} {
    puts [format "%-6s %s" $name [get $op]]
}
# Optional memory dump as the CPU sees it, for regions the debug bus cannot reach:
# quartus_stp -t tools/hps_jtag_cpu.tcl <addr> <words> <file>
foreach {addr words file} $quartus(args) {
    set saved_r1 [get 0xE1A00001]
    mem_write [expr {$DBG + 0x80}] $addr
    exec_insn 0xEE101E15 ;# mrc p14, 0, r1, c0, c5, 0
    set f [open $file w]
    fconfigure $f -translation binary
    for {set i 0} {$i < $words} {incr i} {
        set v [get 0xE4910004] ;# ldr r0, [r1], #4
        puts -nonewline $f [binary format i [expr {$v & 0xFFFFFFFF}]]
    }
    close $f
    mem_write [expr {$DBG + 0x80}] $saved_r1
    exec_insn 0xEE101E15
    puts "dumped $words words from $addr to $file"
}

mem_write [expr {$DBG + 0x80}] $saved_r0
exec_insn 0xEE100E15 ;# mrc p14, 0, r0, c0, c5, 0

set dscr [mem_read [expr {$DBG + 0x88}]]
mem_write [expr {$DBG + 0x88}] [expr {$dscr & ~((1 << 13) | (1 << 14))}]
mem_write [expr {$DBG + 0x90}] 6
after 20
puts "restarted, DSCR [mem_read [expr {$DBG + 0x88}]]"
dap_close
