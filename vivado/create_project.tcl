# Recreate the Vivado project for the Basys 3 eye-drowsiness CNN.
# Usage (from the repo root, Vivado Tcl console or batch):
#   vivado -mode batch -source vivado/create_project.tcl
# NOTE: this script was written from the team's original project settings
# (part xc7a35tcpg236-1, Vivado 2024.2) but has NOT been executed in Vivado yet.
set root [file normalize [file join [file dirname [info script]] ..]]
create_project cnn_eye_drowsiness $root/vivado/build -part xc7a35tcpg236-1 -force

# --- design sources (only the modules the top actually uses) ---
add_files -norecurse [list \
  $root/rtl/basys3_wrapper.v \
  $root/rtl/cnn_top.v \
  $root/rtl/rom_weights.v \
  $root/rtl/conv1_layer.v \
  $root/rtl/conv2_layer.v \
  $root/rtl/fc_layer.v \
  $root/rtl/mac_pipe.v \
  $root/rtl/mac_pipe_lut.v \
  $root/rtl/mac_sel.v \
  $root/rtl/relu_requant.v \
  $root/rtl/maxpool2x2.v \
  $root/rtl/seven_seg_drive.v ]
# rom_weights.v loads these with $readmemh("<name>.mem"): they must be part of the project
add_files -norecurse [glob $root/ml/export/*.mem]
set_property file_type {Memory File} [get_files -of_objects [get_filesets sources_1] *.mem]

add_files -fileset constrs_1 -norecurse $root/constraints/basys3.xdc
add_files -fileset sim_1 -norecurse [list \
  $root/sim/tb_cnn.v \
  $root/sim/tb_conv1_layer.v \
  $root/sim/tb_conv2_layer.v \
  $root/sim/tb_fc_layer.v ]

set_property top basys3_wrapper [get_filesets sources_1]
set_property top tb_cnn         [get_filesets sim_1]
update_compile_order -fileset sources_1
update_compile_order -fileset sim_1
puts "RTL source: [get_files -of_objects [get_filesets sources_1] rtl/rom_weights.v]"
puts "Design top: [get_property top [get_filesets sources_1]]"
puts "Simulation top: [get_property top [get_filesets sim_1]]"
puts "Project created. Run Synthesis -> Implementation -> Bitstream, and check docs/STATUS_AND_ISSUES.md (timing)."
