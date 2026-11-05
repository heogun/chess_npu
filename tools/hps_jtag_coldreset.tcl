# Usage: quartus_stp -t tools/hps_jtag_coldreset.tcl
# Requests an HPS cold reset, so the Boot ROM runs again. Only volatile HPS state changes.
# The JTAG link drops during the reset, so this script ends right after the request.
source [file join [file dirname [info script]] hps_dap.tcl]

dap_open
use_ahb
catch { mem_write 0xFFD05004 1 }
puts "cold reset requested"
catch { dap_close }
