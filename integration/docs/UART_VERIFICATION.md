# UART Verification Record

## Current UART build: upstream fixed-point export (2026-11-02)

Baseline: `f9654aa971bc0ee45e52cd35baa335ecd28d85bd`, branch `feature/uart`, S1=10, S2=6. No new project commit or push.

- Updated to the complete upstream weights, biases, images and golden outputs. UART protocol, signed int32 logits and temporal thresholds remain unchanged.
- The primary Icarus regression ran 22 configurations: 20 PASS, one FC-reference failure and one real-UART timeout. The new upstream FC testbench hardcoded old logits (1326/-363 instead of 492/727 for slot 0). Replaced constants with checked loading of current expected.txt and reran the FC test: PASS. The identical real-UART serial-pin test subsequently PASS in Vivado xsim with 87 checked results (`build/uart_upgrade_xsim_console.log`). All other common simulation source hashes match between the primary and FC repair runs. All 22 checks are resolved across these runs/simulators; the original failure/timeout evidence remains available. This is not a claim that the full 22-case Icarus command passed on its own.
- Primary evidence: `build/verify_20261102_155509_884708/summary.json`. FC repair evidence: `build/verify_20261102_155941_687798/summary.json`. Consolidated result: `build/uart_hw_20261102_155516/verification_summary.json`.
- Real CNN matches 16/16 new golden logit pairs, 14/16 labels. Both real and stub serial-pin tests PASS with 87 checked results each, including directed SW13 low-confidence hold while reporting the raw class. Internal CNN latency remains 37,290 cycles / 372 us at 100 MHz.
- Added all three upstream layer tests to the portable runner. ReLU vectors now use S2=6. Missing vectors terminate simulation with a nonzero exit; this negative test PASS replaces the old false-PASS behavior.
- Independent core shell regression: ALL TESTS PASSED (`build/uart_upgrade_core.log`). Five host CLI unit tests PASS. Shell regression uses a unique output directory and retains existing builds.
- Fresh Vivado 2025.2 post-route implementation at 100 MHz: setup +1.511 ns, hold +0.049 ns, 1,372 LUT, 1,405 registers, 6.5 BRAM and 3 DSP. No unclocked registers, unconstrained internal endpoints or timing loops. Existing asynchronous I/O exceptions remain explicit.
- Bitstream: `build/uart_hw_20261102_155516/drowsiness_top.bit`, SHA256 `57D6EC51CB032FFCCEC2E4167C59516D56DB4744F44A97FC390850ABA06B1568`. Source hashes, raw timing/utilization/DRC reports and checkpoints are retained alongside it.
- DRC still reports three DSP input-pipeline warnings and 20 RAMB18 asynchronous-control warnings in the CNN hierarchy, plus the report-limit notice. Do not describe this build as warning-free.
- Physical validation of this new bitstream is pending. User-reported COM6 tests and the captured 70-record sequence validate the earlier e9bc475-based UART build only. No board was programmed as part of this update.
- CONF_MARGIN stays 1024 pending calibration. Updated slot 0 has margin 235, class OPEN, ground-truth CLOSED; slot 1 has class CLOSED, ground-truth OPEN. Demo errors remain expected model misses.
- Export provenance limitation remains: upstream quantize_export.py does not emit the new nw*/na* metadata. No invented floating-point scale or dequantization is added to UART.

### Commands executed for this update

```powershell
.\.venv\Scripts\python.exe integration/scripts/verify_uart.py
.\.venv\Scripts\python.exe integration/scripts/verify_uart.py --only tb_fc_layer
.\.venv\Scripts\python.exe -m unittest discover -s tools -p test_uart_cli.py -v
vivado -mode batch -source integration/scripts/build_uart.tcl
```

The shell regression used Git Bash with PYTHON pointing to the local virtual environment. See its log above. Use UART.md for physical acceptance steps and current expected output.

## Historical evidence: e9bc475-based build

Date: 2026-11-02. Base revision: `e9bc475a66ff3d6fcb8a000123fbc7158cb880d4`; branch: `feature/uart`, uncommitted working changes. No CNN arithmetic/model export changes are included.

## Baseline and software

- Committed baseline was materialized and tested separately from working changes: all 11 original testbenches PASS. CNN matches 16/16 golden logit pairs, with 14/16 correct demo labels.
- Baseline evidence: `build/verify_20261102_121023_293818/summary.json` and individual command/compile/simulation logs.
- Host CLI: five standard-library unit tests PASS on Python 3.14.0. Cases cover interleaved monitoring, errors, partial reads, timeout without retries and record validation.
- pySerial 3.5 was installed only in the local `.venv`; port enumeration executed successfully. Enumerated ports were Bluetooth serial ports; no identifiable Basys3 USB-UART port was present. Physical UART operation remains unverified.
- The same local virtual environment also imports NumPy 2.3.5 successfully on Python 3.14.0 for the documented repeatable test setup; no system-wide Python package was installed.
- Numerical vector-generation runtime: Python 3.12.14 / NumPy 2.3.5. RTL simulation: Icarus/vvp 12.0 devel. The simulation runner records source hashes and exact compile commands in each evidence directory.

## Final working-tree regression

All **18 test configurations PASS**, evidence in `build/verify_20261102_122226_241709/summary.json` and individual logs:

| Scope | Executed result |
|---|---|
| Original core, arithmetic helpers, input/display/ROM/FSM/controller and accelerated tops | 11 PASS; CNN matches 16/16 golden logit pairs and 14/16 labels |
| UART RX/TX | Loopback, zero/ones/alternating/random bytes, false start, bad stop, recovery, reset and baud variation +/-2% PASS |
| Command parser | Every slot 0-15, LF/CRLF, malformed/range/overflow/framing recovery and reset PASS |
| ASCII output | All reply messages, zero, signed int32 extremes, uint32 maximum and reset PASS |
| Latency conversion | Zero, rounding boundaries and maximum 20-bit cycle count at 50 and 100 MHz PASS |
| UART system with stub | 84 checked results; all 16 PC slots, board manual/sequence, golden/temporal oracle, busy SLOT/RUN, deferred mode changes, masked controls, command errors/flood/overrun and reset recovery PASS |
| UART system with real CNN | Same serial-pin scenarios and 84 checked results PASS; active pipeline latency remains 37,290 cycles |

The real/stub serial-pin tests include an accelerated sequence timer faster than UART throughput, exercising backpressure and retained frame identity. The temporal oracle uses exported golden predictions rather than trusting the DUT's reported logits. Original board tests use UART_ENABLE=0 to preserve their synthetic cadence; enabled UART behavior is covered separately above.

Vivado xsim independently ran `tb_uart_phy` and real-CNN `tb_uart_system` through the updated simulation-source Tcl flow: both PASS, including 84 checked system results. Evidence: `build/uart_xsim_console.log` and `build/uart_xsim_check/project/`. xsim warned that the large expected/received-line arrays exceed the waveform display limit; these arrays were still used by the scoreboard and the simulation completed successfully. No claim is made that every testbench was rerun under xsim.

## Implementation

Fresh build: `build/uart_hw_20261102_122018/`, Vivado 2025.2 build 6299465, `xc7a35tcpg236-1`, top `drowsiness_top`, 100 MHz.

| Metric | Measured post-route value |
|---|---:|
| Worst setup slack | +2.052 ns |
| Worst hold slack | +0.033 ns |
| Slice LUTs | 1,372 |
| Slice registers | 1,408 |
| Block RAM tiles | 6.5 |
| DSP | 3 |
| Inferred latches | 0 |
| Registers with no clock | 0 |
| Unconstrained internal endpoints | 0 |
| Combinational/latch loops | 0 |

Bitstream generation completed successfully. SHA256 of `drowsiness_top.bit`:

`DA7A6B038686D07FE608126A836AD33CA398167EC60A73E17C650DCA6F8AA539`

Reports: `timing.rpt`, `utilization.rpt`, `check_timing.rpt`, `clocks.rpt`, `drc.rpt`. Indicators and UART TX have explicit asynchronous output exceptions; asynchronous input paths into synchronization are exempted. This does not assert a synchronous external-device timing budget.

DRC warnings remain: three DSP input-pipelining warnings and 20 reported RAMB18 asynchronous-control warnings within the existing CNN memory/MAC hierarchy, plus the warning-report limit notice. These were not suppressed or described as zero warnings. The source CNN hierarchy is unchanged; review reset behavior during physical validation. Bitstream success is not proof of board correctness.

## Failures found and resolved

- The first testbench attempted to format directly into an indexed memory element, unsupported by the simulator; changed to a temporary expected-record register.
- Carriage-return stimulus used an escape not accepted as intended by the Verilog simulator; changed to explicit octal CR.
- A testbench asynchronous wait observed a transient quiescent value before the queued OVERRUN message started; readiness assertions now sample on clock edges. The actual reply was present and is now checked.
- Initial implementation failed setup by -0.409 ns on combinational cycles-to-microseconds division. Replaced it with a 20-cycle restoring divider. The final positive timing values above apply to that implementation.

Earlier failed/superseded logs remain in ignored build directories for traceability. A superseded long simulation was stopped after the final source/runner replaced it; do not count that stopped run as a successful test.

## Remaining physical evidence

No board was programmed during this task. Board inference, USB-UART round trips, driver/cable operation, physical switch manipulation and photo/video acceptance remain pending. Use the checklist in UART.md and record the actual COM port, bitstream hash, tested slots, warning sequences and observations when hardware is available.

## 2026-11-02: Physical validation of the updated UART build

User-supplied COM6 terminal output confirms PC runs for slots 0-9 (10 records) and board-button monitoring for slots 0-15 (16 records). All 26 supplied records match the f9654aa golden logits and predicted classes. Every supplied record reports 37,290 cycles / 372 us and AWAKE. No UART error or malformed record appears in the supplied excerpt. The operator previously reported programming build/uart_hw_20261102_155516/drowsiness_top.bit; the new slot-3 logits also distinguish it from the old export. This is operator-provided hardware evidence, not an independently instrumented observation or an exhaustive UART robustness test.

Remaining physical checks: updated-build sequence and warning recovery, PC runs for slots 10-15, SW13 hold, reset during an active transaction and ownership handover during output. Slots 0/1 remain known model classification misses relative to ground truth, despite matching the numerical golden reference.

## 2026-11-02: Updated-build physical sequence capture

Validated an operator-supplied COM6 terminal capture containing 105 complete SEQ records against the f9654aa export and DrowsyRef initialized from reset. All 105 slot positions, golden logit pairs, raw classes, temporal warning states and latency fields match. Each record reports 37,290 cycles / 372 us. No ERR line or malformed RESULT appears in the supplied capture.

Warning transitions (one-based capture frame): 1 AWAKE, 36 DROWSY, 47 MICROSLEEP, 60 DROWSY, 78 AWAKE, 100 DROWSY. The capture includes one full 64-frame loop and 41 frames of the next loop, including full MICROSLEEP recovery across the loop boundary. Counts: 57 AWAKE, 35 DROWSY, 13 MICROSLEEP.

Local evidence: build/hardware_20261102_COM6_sequence/serial.log and summary.json. This validates the supplied observation sequence, not calibrated elapsed closure durations or electrical fault tolerance. Physical PC slots 10-15, SW13 hold, active-transaction reset and ownership handover remain separate checks.
