# Status and known issues

_State of the material handed over on 2026-10-30, updated 2026-11-03 for the pipelined core. "Verified" means it was re-run for this repo; everything else is as reported in the original files._

## Verified (Icarus Verilog + numpy, `./run_sim.sh`)
- The pipelined `rtl/cnn_top.v` (conv1/conv2/fc layers, fixed-point export
  S1 = 10, S2 = 6) reproduces all **16/16** golden logit pairs of `ml/export/expected.txt` (14/16 correct
  classes; images 0 and 1 are the deliberately included model misses).
- Original `rtl/legacy/cnn_top_original_buggy.v` reproduces the failure in `docs/reports/xsim_simulate_ORIGINAL_buggy_rtl.log`.
- Unit tests of `conv_pe`, `relu_requant` and conv+ReLU+pool vs. `expected_a1/a2`: 0 errors.
- Board top `integration/` (`drowsiness_top` + `cnn_top`): 12 Icarus testbenches PASS (16 slots bit-exact,
  37,290 cycles/image); Vivado 2025.2.1 at 100 MHz: WNS +2.385 ns, WHS +0.091 ns, 601 LUT / 700 FF / 6.5 BRAM /
  3 DSP (2 Nov build, without UART).
- Basys 3 board test of that 100 MHz fixed-point (S2 = 6) bitstream: **passed** (3 Nov; manual slots,
  sequence mode incl. slow / step / scan, low-confidence hold, latency view `0372`).
- int8 accuracy re-computed from the exported weights: train 97.23 % (758), valid 94.44 % (216), test 98.15 % (108).
- `examples/digits-demo-basys3`: its `tb_cnn_core` passes under Icarus (0/16 bit mismatches, 15/16 correct).

## Not verified / open
1. **Timing (solved 2 Nov):** the old critical path was `a1_idx` arithmetic →
   484-entry `a1_mem` read mux → multiply/add → `acc2` (17.26 ns, later 16.6 ns
   for the one-MAC core). Registered (synchronous) buffer reads in the pipelined
   core fixed it; the UART build (`integration/scripts/build_uart.tcl`) still
   needs its own timing report.
2. Bitstreams are not committed; the board demo still needs a photo/video record.
3. `vivado/create_project.tcl` (stand-alone `basys3_wrapper` project) has not been
   run in Vivado; the integration scripts (`integration/scripts/`) are the tested flow.
4. **Dataset / evaluation caveat.** All 756 train and 108 test label files come from the same subject (`s0001_*`) and their frame numbers interleave (train 4–3240, test 69–3221), so neighbouring near-identical frames likely sit on both sides of the split. The 98 % test figure therefore says little about unseen people; the validation set is 216 crops. A subject-wise split (or another dataset) is needed before claiming real-world accuracy. Also, the class counts in the `.npz` files differ slightly from the eye-state flag in the file names (e.g. train 328 open in npz vs 309 in file names) — worth a label check (my reading of the file-name convention is an assumption).
5. Raw dataset copy handed over was incomplete (train: 11 of 756 images present, valid: none), most likely a partial download. The crops (`ml/*.npz`) are complete, so training/export is reproducible; `prepare_data.py` is not without re-downloading the dataset.
6. Minor: comment in `basys3_wrapper.v` lists `W15` for `sw[3]`; the XDC (correct for Basys 3) uses `W17`. `ml/export/` and the Verilog sources use Windows (CRLF) line endings; `.gitattributes` normalises them.
7. The CNN classifies a stored 24×24 eye crop. Camera input, face/eye localisation and the "ADAS" decision logic (e.g. PERCLOS / eyes-closed duration) are outside this repo.

## Suggested next steps
1. Record the board demo (photo/video + which `SW` values give which result) and
   save the Vivado timing / utilization reports of the final build.
2. Redo the split by subject / use more subjects; report precision/recall for *closed* eyes (the safety-relevant class).
3. Optionally use the unit-tested `conv_pe` for more parallel taps if latency matters.
4. Add a `LICENSE`, fill in the team roles, tag a release containing the bitstream.
