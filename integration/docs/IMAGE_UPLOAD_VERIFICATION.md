# Image-input verification — 2026-11-03

The real CNN accepts new 24x24 uint8 eye crops through UART, while retaining
ROM and board modes. Protocol and commands: [IMAGE_UPLOAD.md](IMAGE_UPLOAD.md).

## Reviewable evidence

Selected reports, source fingerprints, host logs, simulation summaries,
operator captures, and the two non-ROM demo crops are committed in
[the evidence archive](../../docs/reports/uart_image_upload_20261103/README.md).
Its archive_manifest.json preserves each original path and SHA256; generated
projects, checkpoints and bitstreams remain in ignored build/ directories.

Original verification base: 69a3e046c683ecc0d932fe74e9ef83a073d6006f.
The feature branch codex/uart-image-upload integrates upstream main 56c0237;
post-integration testing used tree 9d8bff9707c5c8c3df5e641a81e9a0e389f2c059.
This preserves the team's updated documentation, shift consistency guard,
stub latency defaults and dynamically checked core testbench.

## Executed checks

- Original Icarus regression: 21 checks PASS, including all CNN layers, 16/16
  golden logit pairs (14/16 labels), missing-vector rejection, board control,
  temporal FSM, real/stub tops, UART units and the 87-result stub system.
  Archive: simulation/original_regression.json.
- Original real-CNN upload: PASS, 37 serial-pin frames. These comprise all 16
  ROM-reference images, byte ramp/black/white synthetic frames, and eight
  CLOSED plus ten OPEN temporal observations. Logits/warnings match the
  integer reference and DrowsyRef. CRC matches Python binascii. Tests cover
  failed-load invalidation, busy, timeout/drain, framing, ID mismatch/reuse,
  reset, deferred ownership and ROM fallback. Archive: original_upload.json.
- Original xsim independently passes the upload test and 87-result real-CNN
  UART system. All 23 configurations are resolved across these runs, not one
  complete 23-case Icarus invocation.
- After integrating current main, four targeted Icarus checks PASS: tb_cnn,
  tb_top, tb_fc_layer and tb_uart_command. The upstream shift guard executes
  during vector generation. Archive: simulation/integrated_targeted.json.
- Post-integration xsim passes tb_uart_upload (37 checked frames) and
  tb_uart_system (87 real-CNN results). Logs are archived as
  simulation/integrated_tb_uart_upload.txt and integrated_tb_uart_system.txt.
- Sixteen host tests PASS on Python 3.14.0, pySerial 3.5 and Pillow 12.3.0:
  existing CLI, CRC/binary/partial writes, IDs, no automatic retry, raw/.mem
  input, PNG/RGB resize, and physical-checker rejection logic. Archive:
  simulation/host_tests.txt. These mock host tests are not physical tests.

Accelerated simulation baud does not establish physical high-baud operation.
The first upload run's missing sequence-file error was rejected despite its
printed PASS; only the corrected clean runs above count as passed evidence.

## Build results

Vivado 2025.2 build 6299465, xc7a35tcpg236-1, top drowsiness_top.

| Post-route metric | Image upload | Previous UART build |
|---|---:|---:|
| Clock | 100 MHz | 100 MHz |
| Worst setup slack | +1.273 ns | +1.511 ns |
| Worst hold slack | +0.037 ns | +0.049 ns |
| LUTs | 1,677 | 1,372 |
| Registers | 1,639 | 1,405 |
| BRAM tiles | 7 | 6.5 |
| DSP | 3 | 3 |

Original operator-test instructions used
build/uart_hw_20261103_140549/drowsiness_top.bit, SHA256
2162E695E3439840F2CECD674A3FEF5A5245D515B1D33879C938928C91ADB11B.
Reports and 27 build-input fingerprints: implementation/operator_tested_build/.

A fresh build after integrating main has the same reported timing/resources:
build/uart_hw_20261103_150217/drowsiness_top.bit, SHA256
C26F9631A72648D20E3A407E8352E5FE1469EDD60BFB48DB27B533CB869B6B85.
Its reports/provenance are in implementation/integrated_build/. This rebuild
has not been programmed during the PR preparation session; physical captures
below belong to the earlier operator session. Rebuild using
integration/scripts/build_uart.tcl when working from a fresh checkout.

The CNN/controller remains 37,290 cycles = about 372.9 us at 100 MHz; integer
telemetry reports 372 us. Upload/serial output are excluded. Neither host
end-to-end latency nor a calibrated sampling cadence was measured.

Timing reports show no unclocked registers, unconstrained internal endpoints,
or timing loops. Existing asynchronous I/O exceptions remain explicit. DRC
still reports three DSP pipeline warnings, 20 RAMB18 asynchronous-control
warnings and the report-limit notice. Synthesis reports unused parser
entries/temporaries and the existing deprecated DSP attribute. xsim's large
scoreboard arrays exceed waveform display limits but still execute checks.

## Operator hardware observations on COM6

- First upload: host export slot 3, ID 1, OPEN logits -17106/17976 match.
- Two crops absent from every ROM image: ID 2 CLOSED 8884/-9142 and ID 3 OPEN
  -24956/25692 match independent integer goldens. PNGs, source test indices
  and expected values are in hardware/demo/.
- Forty sequential uploads match DrowsyRef: eight CLOSED (IDs 4-11), then
  32 OPEN (12-43). MICROSLEEP begins at 11, recovery to DROWSY at 21 and AWAKE
  at 37. All logits, latency fields and supplied acknowledgements match.
- User-reported immediate ID-43 reuse produces ERR ID; returning to SLOT 3 /
  RUN produces the legacy source=PC golden result. These two observations
  are reported in chat, without a separate archived serial capture.
- Archived operator-run fault checks PASS: corrupted CRC at ID 100 returns
  ERR CRC; 64/576 pixels at ID 200 returns ERR TIMEOUT; held-btnU reset aborts
  partial ID 300. All subsequently reject RUN_FRAME with ERR NOFRAME and
  report no RESULT during the checked quiet interval. Fresh uploads
  101/201/301 match golden OPEN logits -17106/17976 and 37290 cycles / 372 us.

These are operator-provided/host-checker observations. Reset timing is
manually confirmed, internal cnn_start was not instrumented, and programmed
bitstream identity was not independently read back. The tests cover frame
counts and selected failure modes; they do not establish elapsed closure
durations or exhaustive electrical fault tolerance. Camera capture, eye
localization, stale-history policy and model generalization remain separate
work. Physical ownership handover during output and host end-to-end timing
remain additional acceptance checks.
