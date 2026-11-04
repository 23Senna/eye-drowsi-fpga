# Evidence index

- [Current integrated FPGA build and GUI/host evidence](current_build_20261104/README.md).
- [3 Nov UART implementation and physical fault-test archive](uart_image_upload_20261103/README.md).
- [Current status](../STATUS_AND_ISSUES.md) defines which results apply now.

- [CPU NumPy baseline report](cpu_numpy_20261104/report.json) and
  [measurement method](../../integration/docs/INFERENCE_BENCHMARK.md); not a best-possible CPU comparison.

## Historical original Vivado / simulator reports

These come from the team's own Vivado 2024.2 run for part `xc7a35tcpg236-1` (Basys 3), at a 100 MHz clock constraint.
These files describe the original failing design, before the repaired and
filter-parallel cores. They do not describe current rtl/cnn_top.v. The
current integrated implementation reports are linked above.
The timing report is trimmed to its summary and the worst setup path; the rest of the Vivado project (checkpoints, logs, waveform DB, bitstream) is intentionally not in the repo.

| File | What it shows | Key numbers |
|---|---|---|
| `impl_utilization_placed.rpt` | Post-placement utilisation | 5063 LUT (24.3 %), 9858 FF (23.7 %), 5 BRAM tiles (10 %), **0 DSP**, 34 IOB |
| `synth_utilization.rpt` | Post-synthesis utilisation | – |
| `impl_timing_summary_routed.rpt` | Timing (trimmed) | **WNS −7.232 ns**, TNS −20274.7 ns, 9352 / 19730 setup endpoints failing, hold OK (WHS +0.056 ns) |
| `impl_power_routed.rpt` | Power estimate | 0.136 W total (0.064 dynamic), Tj 25.7 °C |
| `impl_drc_routed.rpt`, `impl_route_status.rpt` | DRC / routing | routing complete (13146 nets, 0 errors); warnings only |
| `xsim_simulate_ORIGINAL_buggy_rtl.log` | xsim run of the original `cnn_top.v` | image 0 → `x`, other logits ≠ golden (this is the bug) |
