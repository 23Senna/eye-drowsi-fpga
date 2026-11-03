# Run the real upload and legacy UART tests from an immutable runner snapshot.
# vivado -mode batch -source integration/scripts/verify_upload_xsim.tcl -tclargs <verify_run>/source
if {[llength $argv] != 1} { error "expected one verification source snapshot directory" }
set repo [file normalize [file join [file dirname [info script]] ../..]]
set snapshot [file normalize [lindex $argv 0]]
set output [file join $repo build upload_xsim_[clock format [clock seconds] -format %Y%m%d_%H%M%S]]
if {[file exists $output]} { error "output already exists: $output" }
file mkdir $output
cd $output
create_project uart_input_sim [file join $output project] -part xc7a35tcpg236-1
add_files -norecurse [glob [file join $snapshot rtl *.v]]
add_files -norecurse [glob [file join $snapshot integration rtl *.v]]
add_files -norecurse [glob [file join $snapshot ml export *.mem]]
foreach name {seq stub_logits weights biases} {
    add_files -norecurse [file join $snapshot integration mem $name.mem]
}
foreach name {upload_pixels upload_logits upload_warnings upload_crc} {
    add_files -fileset sim_1 -norecurse [file join $snapshot integration sim vectors $name.mem]
}
foreach name {tb_uart_upload tb_uart_system} {
    set file [file join $snapshot integration sim $name.v]
    add_files -fileset sim_1 -norecurse $file
    set_property file_type SystemVerilog [get_files $file]
}
set_property include_dirs [list [file join $snapshot integration rtl] [file join $snapshot integration sim]] [get_filesets sim_1]
set_property verilog_define FLAT_DATA [get_filesets sim_1]
set_property -name {xsim.simulate.runtime} -value {-all} -objects [get_filesets sim_1]
foreach test {tb_uart_upload tb_uart_system} {
    set_property top $test [get_filesets sim_1]
    update_compile_order -fileset sim_1
    launch_simulation -simset sim_1 -mode behavioral
    set log [file join $output project uart_input_sim.sim sim_1 behav xsim simulate.log]
    set f [open $log r]
    set contents [read $f]
    close $f
    file copy $log [file join $output $test.log]
    close_sim
    if {[string first "PASS $test" $contents] < 0 || [regexp {ERROR:|FATAL:|Fatal:|FAIL} $contents]} {
        error "$test did not produce a clean checked PASS; see $output/$test.log"
    }
    puts "VERIFIED $test"
}
puts "UPLOAD_XSIM_COMPLETE output=$output source=$snapshot"
