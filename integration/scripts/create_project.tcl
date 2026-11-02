# create_project.tcl - batch Vivado 2025.2.1 project for drowsiness_top (Basys3, xc7a35tcpg236-1).
# Usage (from integration/):  vivado -mode batch -source scripts/create_project.tcl [-tclargs stub]
#   default: real build with the CNN team's cnn_top; "stub" = cnn_core_stub build.
# Creates integration/vivado/drowsiness.xpr (throw-away, for scripted builds). For the GUI project use
# your own project + scripts/add_sources.tcl (see docs/VIVADO_BOARD_GUIDE.md).
set fpga [file normalize [file join [file dirname [info script]] ..]]
set USE_STUB [expr {[llength $argv] > 0 && [lindex $argv 0] eq "stub"}]

create_project drowsiness [file join $fpga vivado] -part xc7a35tcpg236-1 -force
set_property target_language Verilog [current_project]
source [file join $fpga scripts add_sources.tcl]
