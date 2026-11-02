# build.tcl - synth / impl / bitstream + reports for the drowsiness project.
# Usage (from integration/):  vivado -mode batch -source scripts/build.tcl [-tclargs synth|impl|bit [project.xpr]]
#   default "bit" on integration/vivado/drowsiness.xpr (scripts/create_project.tcl). Reports go to integration/reports/,
#   the bitstream to integration/drowsiness_top.bit.
set fpga [file normalize [file join [file dirname [info script]] ..]]
set stage [expr {[llength $argv] > 0 ? [lindex $argv 0] : "bit"}]
set xpr   [expr {[llength $argv] > 1 ? [lindex $argv 1] : [file join $fpga vivado drowsiness.xpr]}]
set jobs 4
set rpt [file join $fpga reports]
file mkdir $rpt

open_project $xpr

reset_run synth_1
launch_runs synth_1 -jobs $jobs
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} { error "synthesis failed" }
open_run synth_1
report_utilization    -file [file join $rpt synth_utilization.rpt]
report_timing_summary -file [file join $rpt synth_timing.rpt]
if {$stage eq "synth"} { puts "INFO: synthesis done"; return }

launch_runs impl_1 -to_step route_design -jobs $jobs
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] ne "100%"} { error "implementation failed" }
open_run impl_1
report_utilization    -file [file join $rpt impl_utilization.rpt]
report_timing_summary -file [file join $rpt impl_timing.rpt]
set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
puts "INFO: WNS = $wns ns"
if {$stage eq "impl"} { return }

launch_runs impl_1 -to_step write_bitstream -jobs $jobs
wait_on_run impl_1
set bit [glob -nocomplain [file join [get_property DIRECTORY [get_runs impl_1]] *.bit]]
if {$bit eq ""} { error "no bitstream" }
file copy -force [lindex $bit 0] [file join $fpga drowsiness_top.bit]
puts "INFO: bitstream -> [file join $fpga drowsiness_top.bit]"
