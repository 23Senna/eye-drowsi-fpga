# add_sim_sources.tcl - add the testbenches to the OPEN Vivado project (simulation set sim_1).
# Called at the end of add_sources.tcl; can also be sourced on its own.
# Testbenches (choose one: Sources -> Simulation Sources -> right-click -> Set as Top):
#   tb_top_real       full top level with the CNN team's cnn_top (default top, ~76 ms simulated)
#   tb_drowsy_fsm     drowsiness FSM vs drowsy_ref.py      tb_input_control / tb_alert_control   unit tests
#   tb_roms           integration ROMs                      tb_cnn_control   alternative CNN sequencer
# (tb_top = stub build, Icarus only.) Every testbench prints one line "PASS ..." or "FAIL ..." in the Tcl console.
# Data files are added to sim_1 so Vivado copies them next to the simulator; FLAT_DATA tells the testbenches
# to open them by plain file name (sim/tb_paths.vh). Run `GEN=1 bash sim/run.sh` once first (makes sim/vectors).
set fpga [file normalize [file join [file dirname [info script]] ..]]
set sim  [file join $fpga sim]

foreach f {drowsy_trace seq_expected expected_a1 expected_a2} {
    if {![file exists [file join $sim vectors $f.mem]]} {
        error "missing sim/vectors/$f.mem - run `GEN=1 bash sim/run.sh` (Git Bash, in [file dirname $sim]) first"
    }
}
set tbs {}
foreach t {tb_top_real tb_drowsy_fsm tb_input_control tb_alert_control tb_roms tb_cnn_control} {
    lappend tbs [file join $sim $t.v]
}
set extra_rtl {}
foreach m {image_rom weight_bias_rom cnn_control} { lappend extra_rtl [file join $fpga rtl $m.v] }
set data {}
foreach f {seq stub_logits weights biases} { lappend data [file join $fpga mem $f.mem] }
foreach f {drowsy_trace seq_expected expected_a1 expected_a2} { lappend data [file join $sim vectors $f.mem] }

set fs [get_filesets sim_1]
foreach f [get_files -quiet -of_objects $fs] { remove_files -quiet -fileset sim_1 $f }
add_files -fileset sim_1 -norecurse $tbs
add_files -fileset sim_1 -norecurse $extra_rtl
add_files -fileset sim_1 -norecurse [list [file join $sim tb_paths.vh] [file join $fpga rtl model_params.vh]]
add_files -fileset sim_1 -norecurse $data
set_property include_dirs [list [file join $fpga rtl] $sim] $fs
set_property verilog_define FLAT_DATA $fs
set_property top tb_top_real $fs
set_property top_lib xil_defaultlib $fs
set_property -name {xsim.simulate.runtime} -value {-all} -objects $fs     ;# run until $finish
update_compile_order -fileset sim_1
puts "INFO: [llength $tbs] testbenches added to sim_1 (top tb_top_real)"
