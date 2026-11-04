# CPU versus FPGA inference benchmark

Run from the repository root:

```powershell
.\.venv-camera\Scripts\python.exe tools\benchmark_inference.py
```

This starts no camera, UART or training. It uses the current exported integer
weights/shifts and preloaded 24x24 uint8 inputs, batch size one. The CPU CNN
uses NumPy int32 matrix multiplication with vectorized window packing and
int32 accumulator safety bounds. It includes input widening, patch packing,
intermediate allocations, requantization, pooling, FC, argmax and Python call
overhead. It excludes model initialization, image preprocessing, files,
UART and display. It does not benchmark the slow golden implementation:
the golden is used outside timing to check exact logits for all 16 exported
inputs plus 64 deterministic random inputs.

The FPGA comparison is 7,996 cycles at 100 MHz = **79.96 us**, from previously
validated board telemetry. This script does not make a fresh FPGA measurement
or time the whole webcam system. The displayed integer `us=79` truncates the
fraction; use cycle count divided by clock frequency for comparison.

Default procedure: 300 warmup calls, then five repetitions of 5,000 separate
batch-one measurements with perf_counter_ns. Outputs under ignored
build/benchmarks/<timestamp>/ contain raw timing samples, per-repeat median,
pooled median/percentiles, CPU/OS/library versions, power scheme and export
hashes. Optional --samples, --repeats, --warmup, --fpga-cycles and --clock-hz
make the comparison configuration explicit.

## Initial workstation observation, 2026-11-04

- AMD Ryzen 9 5900HS, Balanced power plan, NumPy 1.26.4.
- 25,000 measured inferences after warmup; all 80 correctness checks passed.
- CPU pooled median **152.8 us**, p95 **226.7 us**.
- Repeat medians: 152.2, 151.4, 152.4, 156.7, 152.2 us.
- CPU median / FPGA inference = **1.911x**.
- [Archived report](../../docs/reports/cpu_numpy_20261104/report.json) and
  [summary](../../docs/reports/cpu_numpy_20261104/summary.txt). Raw timing samples
  remain local under build/benchmarks/20261104_181722_122542/.

Report this as a speedup **against this NumPy int32 software baseline on this
CPU**, not against all CPU inference. NumPy integer matmul is not a specialized
native INT8 convolution runtime. An optimized PyTorch/ONNX/other CPU backend
could change the conclusion; FP32 implementations also differ numerically
from the FPGA and must be labelled separately. No affinity, clock lock,
exclusive CPU use or temperature control was applied. Record power/battery
conditions and close competing applications for a controlled repeat.

For a new physical FPGA cross-check, stop live GUI/camera senders first, run
one valid UART upload on the programmed board and record RESULT cycles.
Compare that cycle count to the script's explicit FPGA cycle parameter.
UART roundtrip is a different measurement and must not replace internal
inference cycles in this compute-only ratio.
