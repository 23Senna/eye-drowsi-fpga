# Development Progress

## 2026-11-02 UART control and telemetry

Base revision: e9bc475; development branch: feature/uart. Source changes are not committed or pushed.

- Implemented 115200 8N1 UART, ASCII SLOT/RUN protocol and complete RESULT records.
- Added synchronized/debounced SW9 ownership, deferred mode changes and lossless result backpressure.
- Preserved CNN arithmetic/exports and existing board display/temporal behavior.
- Added a Python command-line client with pySerial 3.5 and five passing host tests.
- Reproduced 11 baseline tests; final regression passes 18 configurations, including real-CNN serial-pin tests over all 16 slots and timed sequences.
- Implemented/routed at 100 MHz: setup +2.052 ns, hold +0.033 ns; 1,372 LUT, 1,408 registers, 6.5 BRAM and 3 DSP. Bitstream generated successfully.
- Physical board UART validation remains pending: only Bluetooth serial ports were identified on the test PC. No board was programmed.

See integration/docs/UART.md for the protocol and board checklist, and integration/docs/UART_VERIFICATION.md for exact evidence paths, warnings and limitations. Next milestone: record a build-identified physical serial/board demonstration and archive its logs/video.

## 2026-11-02: Upstream fixed-point synchronization

- Fast-forwarded feature/uart to f9654aa and reapplied the preserved UART work without conflicts. Retained an external file backup and a local stash. No project commit/push.
- Adopted upstream S2=6 and complete export. Preserved the ASCII UART contract and CONF_MARGIN=1024.
- Resolved 22 simulation checks, including a targeted FC-reference repair/retest, 16/16 new golden logit pairs and 87 real/stub UART results each. Core shell regression and five host tests PASS.
- Fixed stale S2=7 vectors and stale FC constants. Tests reject missing/unknown vectors. Added the three upstream layer tests and a missing-vector negative test.
- Fresh 100 MHz build: setup +1.511 ns, hold +0.049 ns, 1,372 LUT, 1,405 FF, 6.5 BRAM, 3 DSP. New bitstream is build/uart_hw_20261102_155516/drowsiness_top.bit.
- Follow-up physical evidence confirmed the earlier build on COM6: PC runs, board-button monitoring and a 70-result sequence. These observations do not validate the new fixed-point bitstream; repeat the physical acceptance checklist with the new build.
- Remaining model-owner work: calibrate low-confidence threshold and synchronize the exporter source/metadata. No threshold or invented dequantization change was introduced.

## 2026-11-02: Physical validation of the updated UART build

User-supplied COM6 terminal output confirms PC runs for slots 0-9 (10 records) and board-button monitoring for slots 0-15 (16 records). All 26 supplied records match the f9654aa golden logits and predicted classes. Every supplied record reports 37,290 cycles / 372 us and AWAKE. No UART error or malformed record appears in the supplied excerpt. The operator previously reported programming build/uart_hw_20261102_155516/drowsiness_top.bit; the new slot-3 logits also distinguish it from the old export. This is operator-provided hardware evidence, not an independently instrumented observation or an exhaustive UART robustness test.

Remaining physical checks: updated-build sequence and warning recovery, PC runs for slots 10-15, SW13 hold, reset during an active transaction and ownership handover during output. Slots 0/1 remain known model classification misses relative to ground truth, despite matching the numerical golden reference.

## 2026-11-02: Updated-build physical sequence capture

Validated an operator-supplied COM6 terminal capture containing 105 complete SEQ records against the f9654aa export and DrowsyRef initialized from reset. All 105 slot positions, golden logit pairs, raw classes, temporal warning states and latency fields match. Each record reports 37,290 cycles / 372 us. No ERR line or malformed RESULT appears in the supplied capture.

Warning transitions (one-based capture frame): 1 AWAKE, 36 DROWSY, 47 MICROSLEEP, 60 DROWSY, 78 AWAKE, 100 DROWSY. The capture includes one full 64-frame loop and 41 frames of the next loop, including full MICROSLEEP recovery across the loop boundary. Counts: 57 AWAKE, 35 DROWSY, 13 MICROSLEEP.

Local evidence: build/hardware_20261102_COM6_sequence/serial.log and summary.json. This validates the supplied observation sequence, not calibrated elapsed closure durations or electrical fault tolerance. Physical PC slots 10-15, SW13 hold, active-transaction reset and ownership handover remain separate checks.
