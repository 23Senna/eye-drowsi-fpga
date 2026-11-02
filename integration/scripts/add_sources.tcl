# add_sources.tcl - add the drowsiness design to the Vivado project that is OPEN right now.
# GUI:   open (or create) a Basys3 project, then in the Tcl Console:
#          source {<repo>/integration/scripts/add_sources.tcl}
# Batch: used by create_project.tcl.
# Default = real build: integration RTL (integration/rtl) + the CNN team's cnn_top.v / rom_weights.v and their ROM files
# straight from their git repo (this repo's rtl/ + ml/export/), so a `git pull` is picked up on the next run.
# `set USE_STUB 1` before sourcing = stub build (cnn_core_stub + integration ROMs, no team RTL).
set fpga [file normalize [file join [file dirname [info script]] ..]]
# CNN team's repo: the parent folder when this is <repo>/integration, else ../eye-drowsi-fpga
set team [file normalize [file join $fpga ..]]
if {![file exists [file join $team rtl cnn_top.v]]} { set team [file normalize [file join $fpga .. eye-drowsi-fpga]] }
if {![info exists USE_STUB]} { set USE_STUB 0 }

set srcs {}
foreach m {drowsiness_top input_control drowsy_fsm alert_control} { lappend srcs [file join $fpga rtl $m.v] }
if {$USE_STUB} {
    foreach m {cnn_core_stub image_rom weight_bias_rom} { lappend srcs [file join $fpga rtl $m.v] }
    set mems [glob [file join $fpga mem *.mem]]
    set_property verilog_define USE_STUB [current_fileset]
} else {
    foreach f [list [file join $team rtl cnn_top.v] [file join $team rtl rom_weights.v]] {
        if {![file exists $f]} { error "missing $f - clone the CNN team's repo next to fpga/ as eye-drowsi-fpga" }
        lappend srcs $f
    }
    set mems {}
    foreach m {conv1_w conv1_b conv2_w conv2_b fc_w fc_b images} { lappend mems [file join $team ml export $m.mem] }
    lappend mems [file join $fpga mem seq.mem]
    set_property verilog_define {} [current_fileset]
}
# remove files left over from an earlier run of this script, then add (paths contain spaces -> lists)
foreach f [get_files -quiet -of_objects [get_filesets sources_1]] { remove_files -quiet $f }
foreach f [get_files -quiet -of_objects [get_filesets constrs_1]] { remove_files -quiet -fileset constrs_1 $f }
add_files -norecurse $srcs
add_files -norecurse $mems            ;# $readmemh finds them by bare file name
add_files -fileset constrs_1 -norecurse [list [file join $fpga constraints basys3.xdc]]
set_property top drowsiness_top [current_fileset]
update_compile_order -fileset sources_1
puts "INFO: drowsiness design added to [current_project] (USE_STUB = $USE_STUB): [llength $srcs] RTL files, [llength $mems] .mem files"

# testbenches for the Vivado simulator (skipped in the stub build)
if {!$USE_STUB} { source [file join $fpga scripts add_sim_sources.tcl] }
