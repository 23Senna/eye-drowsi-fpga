# Image-input verification — 2026-11-03

Physical fault follow-up: operator-run host checker evidence is PASS for CRC
corruption (ID 100), partial-transfer timeout (ID 200), and btnU reset during
partial upload (ID 300). Each rejects subsequent RUN_FRAME with ERR NOFRAME,
reports no RESULT in its checked quiet interval, then completes a fresh valid
upload (IDs 101/201/301) with golden OPEN logits -17106/17976 and 37290 cycles /
372 us. Local serial.log and summary.json files were inspected in
build/physical_upload_crc_20261103_144833_159064/,
build/physical_upload_timeout_20261103_144913_782654/, and
build/physical_upload_reset_20261103_144946_468206/.
Consolidated index: build/hardware_uart_upload_faults/summary.json.
Reset timing is manually confirmed by the operator; absence of serial RESULT
does not independently instrument internal cnn_start. Programmed bitstream
identity was not independently read back. Earlier pending-status paragraphs
below describe the implementation session before these operator follow-ups.

Temporal operator follow-up: eight CLOSED uploads (IDs 4-11) followed by 32
OPEN uploads (IDs 12-43) match DrowsyRef for every supplied observation.
MICROSLEEP begins at ID 11, recovery to DROWSY at ID 21 and AWAKE at ID 37.
All logits and latency fields match; the 32-record recovery attachment has
complete acknowledgements and no ERR line. Evidence:
build/hardware_uart_upload_closed_sequence/ and
build/hardware_uart_upload_recovery/. These are observation-count tests;
elapsed closure durations and physical fault recovery remain unmeasured.

Second operator follow-up: frame_id=2 (CLOSED, 8884/-9142) and frame_id=3
(OPEN, -24956/25692) match Python integer goldens for two test crops whose
pixel arrays are absent from all 16 ROM images. Both report source=UPLOAD,
AWAKE, and 37290 cycles / 372 us. Capture and validated summary are retained
in build/hardware_uart_upload_new_images/. This is physical behavior reported
by the operator, with the same build-identity limits as the first capture.

Operator follow-up: one user-supplied COM6 upload (host export slot 3,
frame_id=1) reports source=UPLOAD, class OPEN, logits -17106/17976 and
37290 cycles / 372 us, matching the golden reference. Capture and summary:
build/hardware_uart_upload_first/. This is operator-provided evidence; build
identity is not independently established by that excerpt. The no-board
statements below describe the implementation session before this follow-up.

Base commit: `69a3e046c683ecc0d932fe74e9ef83a073d6006f`, branch feature/uart.
Image-upload changes are local and uncommitted. No commit, push, or board
programming was performed. Protocol/demo: [IMAGE_UPLOAD.md](IMAGE_UPLOAD.md).

## Executed simulation and host checks

- Icarus regression: **21 checks PASS** in
  `build/verify_20261103_140452_875386/summary.json`. Includes real CNN (16/16
  golden logit pairs, 14/16 labels), arithmetic and missing-vector negative
  checks, all three layers, board inputs/display/ROM/controller/temporal FSM,
  stub and real tops, UART PHY/parser/formatter, latency at 50/100 MHz, and
  the 87-result legacy UART stub-system test.
- Icarus upload: **PASS**,
  `build/verify_20261103_140417_256955/summary.json`. 37 serial-pin real-CNN
  frames: 16 original golden images, byte ramp/black/white frames absent from
  the stored-image set, eight closed and ten open temporal observations.
  Logits and warning states match the independent integer/temporal references.
  CRC is cross-checked with Python binascii. Busy, failed-load invalidation,
  CRC, timeout/drain, framing recovery, IDs, duplicate execution rejection,
  partial-upload reset, deferred ownership, and ROM fallback are checked.
- Vivado xsim independently passes **tb_uart_upload** and the **87-result
  real-CNN tb_uart_system** using the final regression's source snapshot.
  Logs: `build/upload_xsim_20261103_140721/tb_uart_upload.log` and
  `tb_uart_system.log`. Invocation log:
  `build/upload_xsim_verified_console.log`.
- **12 Python unit tests PASS** on Python 3.14.0, pySerial 3.5 and Pillow 12.3.0:
  old CLI behavior, binary/CRC, partial writes, malformed/incorrect identity,
  timeouts without retransmission, input-size validation, raw/.mem loading,
  exact 24x24 PNG loading and RGB conversion/resize. Evidence:
  `build/uart_upload_host_tests.log`.

All **23 simulation configurations** are resolved across the Icarus runs and
xsim, with an extra independent xsim upload confirmation. This is not a
claim that one full 23-case Icarus invocation was executed. The upload test
accelerates baud for simulation and does not establish physical high-baud
operation or measured 10 Hz throughput.

The first upload simulation printed PASS but emitted an ERROR because its
sequence-file path was missing; the runner correctly rejected it. The path
was repaired and the clean Icarus and xsim executions above passed. Earlier
failed evidence remains in build/. Initial xsim harness errors were repaired
before the final successful run. RTL arithmetic was not altered to accept a
failing numerical test.

## Implemented build

Vivado 2025.2 build 6299465, xc7a35tcpg236-1, top drowsiness_top.
Final build: `build/uart_hw_20261103_140549/`.

| Post-route metric | Value | Previous UART build |
|---|---:|---:|
| Clock | 100 MHz | 100 MHz |
| Worst setup slack | +1.273 ns | +1.511 ns |
| Worst hold slack | +0.037 ns | +0.049 ns |
| LUTs | 1,677 | 1,372 |
| Registers | 1,639 | 1,405 |
| BRAM tiles | 7 | 6.5 |
| DSP | 3 | 3 |

CNN/controller latency remains 37,290 cycles, about 372.9 us at 100 MHz;
the existing integer telemetry reports 372 us. Upload and serial output
are excluded from that field. No end-to-end hardware latency was measured.

Bitstream: `build/uart_hw_20261103_140549/drowsiness_top.bit`.
SHA256: `2162E695E3439840F2CECD674A3FEF5A5245D515B1D33879C938928C91ADB11B`.

The build directory retains raw reports, routed/synthesis checkpoints,
27 exact build-input copies with source_sha256.json, and a consolidated
verification_summary.json. Build-input hashes match both final simulation
snapshots. Earlier build `uart_hw_20261103_140148` is preliminary; use the
final path above for programming and evidence.

Timing reports show no unclocked registers, unconstrained internal endpoints,
or timing loops. Asynchronous I/O exceptions remain explicit in the existing
XDC. The design is not warning-free: DRC reports three DSP pipeline warnings,
20 RAMB18 asynchronous-control warnings (report limit reached), and the limit
notice. Synthesis also reports unused parser temporaries/line entries and the
existing deprecated DSP attribute. xsim warns about waveform display limits
for large scoreboard arrays; these arrays still participate in checking.

## Physical status and remaining acceptance

Port enumeration found only Bluetooth serial ports, with no identifiable
Basys3 UART port. No board was programmed or observed in this implementation
session. A generated bitstream is not evidence of physical operation.

Next acceptance: program the final bitstream, upload reference and new images,
save a build-identified serial capture, exercise interrupted upload/reset and
ownership, and measure host-to-result latency and a known frame cadence.
Temporal thresholds remain observation-count based, with no timestamp/stale
history policy; reset before a new sequence/session. Camera capture, automatic
eye localization, and model generalization remain separate work.
