// tb_paths.vh - where the testbenches find their data files.
// Icarus (sim/run.sh, run from sim/): ../mem/<file> and vectors/<file>.
// Vivado xsim: scripts/add_sim_sources.tcl adds all data files to the simulation fileset (Vivado copies them
// next to the simulator) and defines FLAT_DATA -> plain file names.
`ifdef FLAT_DATA
  `define MEM(f) f
  `define VEC(f) f
`else
  `define MEM(f) {"../mem/", f}
  `define VEC(f) {"vectors/", f}
`endif
