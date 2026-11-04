# UART control and monitoring

The board accepts selection/run commands and streams CNN results over the onboard USB-UART bridge. The real build also accepts 576-byte image uploads with CRC; see [image input](IMAGE_UPLOAD.md) for the binary protocol and CLI. Weights remain in FPGA ROM. Camera capture/eye localization are not implemented on the FPGA.

## Connection and controls

Use the Basys3 **PROG/UART** micro-USB connector, a data-capable cable and the board's USB-UART driver. UART is **115200 baud, 8 data bits, no parity, one stop bit**, without hardware/software flow control. FPGA `uart_rx` is B18 and `uart_tx` is A18, both LVCMOS33; directions are from the FPGA perspective. No external RS-232-level connection is required. Pin references: Digilent Basys3 Master XDC and reference manual.

| Control | Board ownership (SW9 down) | PC ownership (SW9 up) |
|---|---|---|
| SW0-3 | Select image slot 0-15 | Ignored; use SLOT |
| btnC | Run one image / step sequence | Ignored; use RUN |
| SW10-12, SW14 | Existing scan/step/slow/sequence behavior | Sequence disabled |
| SW13 | Low-confidence temporal hold | Same |
| SW15 | Display latency in microseconds | Same |
| btnU | Reset everything, abort serial transaction | Same |

SW9 is synchronized/debounced. A requested ownership change waits for the active inference and UART output to finish. For immediate cancellation use btnU. The PC slot starts at 0 after reset. The existing sequence-mode transition resets temporal history; an ownership change between manual modes does not itself erase that history.

LEDs and the seven-segment display retain their previous meanings. SW9 has no new dedicated status LED. Until a change takes effect, commands can still receive `ERR MODE` or `ERR BUSY`. Busy on LD4 covers the system FSM, not the whole UART output reservation.

## Commands and replies

Commands are case-sensitive ASCII, terminated with LF or CRLF. Output is CRLF, with no character echo. Empty lines are ignored. `SLOT` accepts one or two decimal digits (including leading zero); the range is 0-15.

```text
PC:   SLOT 3
FPGA: OK SLOT 3
PC:   RUN
FPGA: OK RUN
FPGA: RESULT source=PC slot=3 class=OPEN warning=AWAKE logit0=-17106 logit1=17976 cycles=7996 us=79
```

Wait for the SLOT acknowledgement before RUN. After `OK RUN`, wait for RESULT before the next command. There is no RUN queue. SLOT and RUN are rejected until the previous inference/result transmission completes. An accepted RUN latches the PC slot through the system controller; later switches or requests cannot change that frame.

| Reply | Meaning |
|---|---|
| `ERR MODE` | Valid control command while board owns control |
| `ERR BUSY` | A transaction, output packet or ownership transition prevents control acceptance |
| `ERR RANGE` | SLOT argument is not one/two decimal digits in 0-15 |
| `ERR CMD` | Unknown command or malformed command syntax |
| `ERR OVERFLOW` | More than 32 command characters before newline (terminating CR excluded) |
| `ERR FRAME` | UART stop-bit error; command discarded until a subsequent newline |
| `ERR OVERRUN` | One or more commands exceeded the reply mailbox capacity |

Syntax/range errors are checked before mode/busy. CR is accepted only immediately before LF; embedded CR invalidates the line. Framing/length errors discard through newline before recovery. After line corruption, send a newline to resynchronize, then issue a fresh command. Continuous command floods coalesce into OVERRUN, not one reply per dropped command. An overrun command is never executed.

Reset returns TX to idle high, clears parser/replies/results and restores PC slot 0. It may truncate an in-flight line; discard partial data and restart the PC transaction. The CLI never retries RUN automatically, including after timeout or reset.

## Result records

Every completed frame is reported, whether launched by PC, board button or sequence. The field order is fixed:

```text
RESULT source=<BOARD|PC|SEQ> slot=<0..15> class=<OPEN|CLOSED> warning=<AWAKE|DROWSY|MICROSLEEP> logit0=<int32> logit1=<int32> cycles=<uint> us=<uint>
```

The current export uses S1=10 and S2=6. UART transmits raw signed integer logits without dequantization. CONF_MARGIN remains 1024 raw logit units pending calibration; slot 0 has a margin of 235 and therefore exercises SW13 hold.

Class uses the raw CNN prediction, where class 0/logit0 means CLOSED and class 1/logit1 means OPEN. Equal logits select CLOSED. Warning uses the existing temporal state after that frame, including the optional low-confidence hold; therefore class and warning describe different things. Logits are scores, not probabilities.

`cycles` measures CNN execution using the existing system counter. `us` is floor(cycles / CLK_MHZ), not serial round-trip time or the BCD display's saturated value. At the current 100 MHz configuration, 7,996 cycles yields 372 us in the integer output. Conversion takes 20 small arithmetic steps; decimal formatting uses a separate shift/add-3 converter. Neither changes the CNN arithmetic or execution-cycle count.

Frame data is captured together at `frame_done`. One reserved result is retained until its complete line is transmitted. Replies and RESULT lines never interleave. A RUN acknowledgement precedes its result; otherwise a waiting RESULT takes priority after the current line. The next frame is held while output capacity is occupied. Sequence ticks coalesce while waiting, so sustained throughput is bounded by UART bandwidth. Manual presses during a blocked interval are not queued.

The normal sequence uses 100 ms frames. Faster synthetic sequence timers can be backpressured by serial transmission. Temporal rules remain observation-count based (32-frame window, 13/6 hysteresis, 8 closed to MICROSLEEP, 10 open to recover). Arbitrary PC RUN timing and slowed/stepped sequences are not a calibrated real-time drowsiness measurement.

## PC command line

From the repository root, use a project-local virtual environment:

```powershell
python -m venv .venv
.\.venv\Scripts\python.exe -m pip install -r tools/requirements.txt
.\.venv\Scripts\python.exe tools/uart_cli.py ports
.\.venv\Scripts\python.exe tools/uart_cli.py --port COM5 run --slot 3
.\.venv\Scripts\python.exe tools/uart_cli.py --port COM5 monitor
```

Replace COM5 with the board's actual port. `run` sends SLOT then RUN and prints all replies/results observed while waiting. It returns after the matching PC result. `monitor` sends no commands and prints results from any mode until Ctrl+C. Do not open the same COM port in two terminal programs simultaneously.

Default transaction timeout is 2 seconds; override with `--timeout` before the subcommand if needed. A timeout/error exits without retrying RUN. Monitor idle timeouts simply continue waiting. The CLI validates complete RESULT records; a reset-truncated or malformed record is not treated as valid data.

A serial terminal also works at the same settings: enable newline transmission and type the commands above. The only host runtime dependency is pySerial 3.5. Serial terminal implementation references: https://pyserial.readthedocs.io/en/latest/shortintro.html

## Verification and build

Simulation requires Icarus/vvp on PATH and a Python interpreter with NumPy. The portable runner uses a fresh copy beneath ignored `build/` so vector generation does not rewrite project sources:

```powershell
.\.venv\Scripts\python.exe -m pip install -r integration/scripts/requirements-test.txt
.\.venv\Scripts\python.exe integration/scripts/verify_uart.py --baseline
.\.venv\Scripts\python.exe integration/scripts/verify_uart.py
.\.venv\Scripts\python.exe -m unittest discover -s tools -p test_uart_cli.py -v
vivado -mode batch -source integration/scripts/build_uart.tcl
```

`--baseline` tests committed HEAD, ignoring working changes. The full working-tree runner executes 22 test configurations, including three layer tests, rejection of missing vectors, serial-pin tests with both real and stub CNN and 50/100 MHz timing conversion. `--only tb_uart_command tb_uart_system_real` selects specific cases. NumPy 2.3.5 was used for recorded vector generation; no training framework is needed for these tests.

Use the virtual environment created in the PC setup section. The build command assumes Vivado is on PATH; otherwise invoke the installed Vivado batch launcher by its full path. No serial client or board connection is needed for simulation or implementation.

The original accelerated board tests explicitly disable UART to retain their original artificial frame cadence. New UART-enabled end-to-end tests verify board/PC ownership, all 16 golden slots, manual/sequence telemetry and backpressure through serial pins. A legacy-test PASS alone does not establish UART correctness.

The existing integration shell runner includes UART targets; the portable runner additionally covers the stub-system and 50 MHz conversion variants. Vivado simulation source setup includes the UART testbenches as SystemVerilog test sources. These build flows target `drowsiness_top`; the older root `basys3_wrapper` is not the UART demo top.

The fresh build script reports synthesis/utilization, routed setup/hold, clocks, internal constraint coverage and DRC before bitstream generation. External board switches, indicators and UART are asynchronous interfaces; explicit I/O exceptions do not exempt internal register-to-register paths. See UART_VERIFICATION.md for executed evidence and remaining physical tests.

## Physical acceptance checklist

1. Program the build-identified `drowsiness_top.bit`; reset with btnU.
2. SW9 down: `RUN` returns ERR MODE, button/slot and sequence operate normally, PC monitor receives their results.
3. SW9 up: run all 16 slots from the CLI; compare both logits to the committed expected table. Slots 0/1 remain model classification misses, not UART failures.
4. Confirm display/LED result agreement and SW15 latency; change SW9 while a packet is being sent and verify that frame completes first.
5. Monitor normal, slow, step and scan sequences; record warning transitions and demonstrate low-confidence/display controls where applicable.
6. Reset during a partial command and an active transaction; start a new transaction and verify recovery.
7. Archive serial log and photo/video with source/bitstream identity. Do not claim physical PASS solely from the simulated results.
