# Reproducible fresh implementation; usage: vivado -mode batch -source integration/scripts/build_uart.tcl
# Optional first argument: output directory. Default is a unique build directory.
set root [file normalize [file join [file dirname [info script]] ../..]]
set out [expr {[llength $argv] ? [file normalize [lindex $argv 0]] : [file join $root build uart_hw_[clock format [clock seconds] -format %Y%m%d_%H%M%S]]}]
if {[file exists $out]} { error "output already exists: $out" }
file mkdir $out
cd $out
set_param general.maxThreads 4
create_project uart_check [file join $out project] -part xc7a35tcpg236-1
set source_list {}
foreach m {drowsiness_top input_control drowsy_fsm alert_control uart_rx uart_tx uart_command uart_ascii_tx uart_monitor uart_image_rx} {
    lappend source_list [file join $root integration rtl $m.v]
}
foreach m {cnn_top rom_weights conv1_layer conv2_layer fc_layer mac_pipe relu_requant maxpool2x2} {
    lappend source_list [file join $root rtl $m.v]
}
add_files -norecurse $source_list
foreach m {conv1_w conv1_b conv2_w conv2_b fc_w fc_b images} {
    add_files -norecurse [file join $root ml export $m.mem]
}
add_files -norecurse [file join $root integration mem seq.mem]
add_files -fileset constrs_1 -norecurse [file join $root integration constraints basys3.xdc]
set_property top drowsiness_top [current_fileset]
update_compile_order -fileset sources_1
synth_design -top drowsiness_top -part xc7a35tcpg236-1
report_utilization -file [file join $out synth_utilization.rpt]
write_checkpoint [file join $out synth.dcp]
opt_design
place_design
phys_opt_design
route_design
report_clocks -file [file join $out clocks.rpt]
check_timing -verbose -file [file join $out check_timing.rpt]
report_timing_summary -report_unconstrained -file [file join $out timing.rpt]
report_utilization -file [file join $out utilization.rpt]
report_drc -file [file join $out drc.rpt]
write_checkpoint [file join $out routed.dcp]
set setup [get_property SLACK [get_timing_paths -setup -max_paths 1]]
set hold [get_property SLACK [get_timing_paths -hold -max_paths 1]]
set f [open [file join $out result.txt] w]
puts $f "top=drowsiness_top part=xc7a35tcpg236-1 clock_mhz=100 setup_ns=$setup hold_ns=$hold"
close $f
if {$setup < 0 || $hold < 0} { error "timing failed: setup=$setup hold=$hold" }
write_bitstream [file join $out drowsiness_top.bit]
puts "BUILD_COMPLETE output=$out setup_ns=$setup hold_ns=$hold"
