# UART image input

The real CNN can classify new eye crops sent by a PC without rebuilding the
bitstream. The legacy SLOT/RUN and board/ROM modes remain available. Image
upload is rejected in USE_STUB builds, which do not execute pixel arithmetic.

## PC demonstration

Program a bitstream built from this revision, reset with btnU, and set SW9 up.
Use the board's PROG/UART USB connection at 1,000,000 baud 8N1 (default since 5 Nov;
host tools default to `uart_cli.DEFAULT_BAUD`; a terminal must be set to 1000000). Close other programs
holding the COM port. Replace COM6 with the actual port.

```powershell
.\.venv\Scripts\python.exe -m pip install -r tools/requirements-image.txt
.\.venv\Scripts\python.exe tools/uart_cli.py --port COM6 upload --image eye.png --frame-id 1
.\.venv\Scripts\python.exe tools/uart_cli.py --port COM6 upload --image eye.raw --frame-id 2
.\.venv\Scripts\python.exe tools/uart_cli.py --port COM6 upload --image ml/export/images.mem --slot 3 --frame-id 3
.\.venv\Scripts\python.exe tools/uart_cli.py --port COM6 upload --image docs/reports/uart_image_upload_20261103/hardware/demo/eye_closed.png --frame-id 4
```

`--frame-id` is decimal 0..65535. Use a new ID for each observation. The last
consumed ID cannot be loaded again until another ID is consumed or reset.
An accepted RUN_FRAME consumes the buffer: it cannot be run a second time.
There is no automatic retry after timeout or uncertain delivery.

The .mem example extracts pixels on the PC and sends them over the serial
pins; the FPGA does not use its ROM image for that inference. To demonstrate
input independent of ROM contents, send a new crop or raw image.

Inputs:
- `.raw` / `.bin`: exactly 576 bytes, unchanged.
- `.mem`: 576 whitespace-separated hex byte values, or the 16384-word export
  with `--slot 0..15`. Padding is not transmitted.
- PNG/JPEG and other Pillow-readable files: must already show a cropped eye.
  The host converts to grayscale and resizes to 24x24 using Pillow BOX.
  This is not eye detection. Pillow resizing/grayscale need not reproduce
  OpenCV preprocessing bit-for-bit; use raw pixels for numerical comparisons.

The wire input is always row-major 24x24 uint8 (0..255). No /255 normalization,
file headers, compressed PNG/JPEG content, or ASCII hex is sent as payload.
Weights, biases, shifts and CNN arithmetic are unchanged.

## Wire protocol

Commands are ASCII LF/CRLF. IDs in commands are **exactly four hexadecimal
digits** (upper/lowercase accepted). IDs in replies/results are decimal.
The image dimensions and length are fixed by this protocol; there is no
variable-length field or image-size negotiation.

```text
PC:   LOAD 1234
FPGA: READY 4660
PC:   <576 binary pixels><CRC high byte><CRC low byte>
FPGA: OK FRAME 4660
PC:   RUN_FRAME 1234
FPGA: OK RUN
FPGA: RESULT source=UPLOAD slot=0 class=OPEN warning=AWAKE logit0=... logit1=... cycles=712 us=4 frame_id=4660
```

Wait for each complete acknowledgement. CRC is CRC-16/CCITT-FALSE over the
576 pixels only: polynomial 0x1021, initial 0xffff, no reflection, xorout 0;
check `123456789` = 0x29b1. CRC bytes are big-endian. Payload can include every
byte value, including NUL/CR/LF/XON/XOFF; software flow control stays off.

Replies added:
- `ERR CRC`: complete payload failed checksum; no valid image remains.
- `ERR TIMEOUT`: reception stopped for one second at 100 MHz defaults.
- `ERR FRAME`: UART framing error, including during binary reception.
- `ERR NOFRAME`: RUN_FRAME without a complete unconsumed image.
- `ERR ID`: wrong buffered ID or immediate reuse of the last consumed ID.
- Existing `ERR CMD`, `ERR MODE`, `ERR BUSY`, and mailbox overrun rules remain.

A LOAD replaces/invalidate the previous buffered image. Failed loads never
run inference or advance temporal history. On timeout/framing error, payload
tails are discarded until 100 ms of UART silence; the error is sent after
that drain period. Do not send recovery commands while the receiver drains.
After an uncertain transaction, stop transmitting, wait for the error and a
complete idle interval, then start a new LOAD with a new ID. If state is
uncertain or the board reset during payload, use btnU with the sender stopped,
discard incomplete host responses, and restart the transaction. A reset
cannot distinguish late payload bytes from future ASCII commands.

Upload, inference and output reserve the interface. SW9 handover waits for
the active upload and reply/inference/output to finish. Returning to board
ownership invalidates an unconsumed upload. btnU aborts immediately.
Do not launch SLOT/RUN/another upload before the previous reply/result.

## Architecture and timing

uart_rx -> uart_image_rx (576-byte synchronous-read RAM + CRC) -> cnn_top
image loader -> existing img_mem -> Conv1 -> Conv2 -> FC.

cnn_top latches the image source at start. Its external read port has the
same one-clock read latency as the image ROM, retaining the existing loader
and layer timing. Writes occur only during upload; computation starts only
after validation. The first implementation uses one staging buffer, with
no overlapping upload/inference. ROM mode remains the default for standalone
cnn_top instances. Weights/biases stay in ROM.

Link latency (5 Nov). `UART_BAUD` defaults to 1,000,000 (divider exactly 100 at
100 MHz; `tb_uart_phy` runs at that divider including the baud-tolerance cases).
`build_uart.tcl <out> 115200` still builds a legacy-baud bitstream. Modelled
per-frame transaction (`python tools/fake_fpga.py --baud B --usb-ms U`,
cumulative ms to READY / OK FRAME / OK RUN / RESULT):

| Baud | FTDI latency timer | READY | OK FRAME | OK RUN | RESULT |
|---|---|---|---|---|---|
| 115200 | 16 ms (Windows default) | 18 | 86 | 105 | 114 |
| 115200 | 1 ms | 3 | 56 | 59 | 69 |
| 1000000 | 16 ms | 17 | 40 | 57 | 58 |
| 1000000 | 1 ms | 2 | 9 | 11 | 12 |
| **board 5 Nov** 1000000 | 1 ms | | | | **11.5** (p90 12.8) |

Board run 5 Nov (COM4, day6 bitstream, 297 live frames): measured transaction 11.5 ms
median, matching the model; golden slot-3 upload `cycles=702 us=7` logits -17106/17976.

The FTDI driver holds short replies until its latency timer expires, so every
acknowledgement wait costs up to 16 ms by default. Set it to 1 ms once per PC:
Device Manager -> Ports -> USB Serial Port (COMx, the Basys3 one) -> Properties ->
Port Settings -> Advanced -> Latency Timer = 1. The protocol (CRC, IDs, errors,
three acknowledgement waits) is unchanged; merging LOAD/RUN would save only
about 2-3 ms more at these settings. Inference is 0.08 ms of the total.
Measure the real numbers with `tools/live_webcam.py`, which prints a per-stage
latency summary on exit and stores it as `latency.txt` in the session folder.
`cycles/us` measure CNN/controller latency, excluding upload and serial output.
`slot=0` is a compatibility field for uploads, not a ROM source identifier;
use source=UPLOAD and frame_id to identify the observation.

Temporal rules still count completed observations. They do not acquire camera
timestamps, enforce sampling cadence, or clear stale history on an upload gap.
Reset before a new demo/session; maintain/log a known frame cadence before
interpreting frame counts as closure durations. SW13 still controls the
existing low-confidence hold. Camera capture and eye localization are host work.

## Verification

Executed results and the final bitstream are recorded in [verification evidence](IMAGE_UPLOAD_VERIFICATION.md).

```powershell
.\.venv\Scripts\python.exe -m unittest discover -s tools -p 'test_uart*.py' -v
.\.venv\Scripts\python.exe integration/scripts/verify_uart.py --only tb_uart_upload
```

The upload test drives serial RX/TX pins with the real CNN and checks all 16
exported logit pairs, three synthetic images (byte ramp, black, white), and
18 closed/open temporal frames against the NumPy integer model and DrowsyRef.
It also checks CRC rejection, missing frames, timeout/drain, framing recovery,
wrong IDs, duplicate execution rejection, reset, deferred ownership and ROM
fallback. Its baud is accelerated for simulation; that is not a physical
high-baud claim. Generated data stays in each runner's build snapshot.

Physical acceptance: repeat golden uploads on the programmed board; upload an
image absent from ROM; record IDs, logits, cadence and host end-to-end latency;
interrupt transfer/reset/switch ownership; confirm recovery with no false
inference. Preserve the bitstream hash with the serial capture.

## Operator fault checks

`tools/check_upload_faults.py` provides explicit hardware commands (not an
automatically executed test). Keep SW9 up/SW13 down and close other serial
clients. Reset with btnU before starting the first check, then wait one second.

```powershell
.\.venv\Scripts\python.exe tools/check_upload_faults.py --port COM6 --test crc --frame-id 100
.\.venv\Scripts\python.exe tools/check_upload_faults.py --port COM6 --test timeout --frame-id 200
.\.venv\Scripts\python.exe tools/check_upload_faults.py --port COM6 --test reset --frame-id 300
```

Each command checks rejection, ERR NOFRAME on attempted execution, a quiet
serial interval without RESULT, and a valid slot-3 pixel upload with the next
ID matching golden logits -17106/17976. A failure stops the check; do not
continue other cases until the cause is understood. Logs and summary.json
are saved beneath a unique build/physical_upload_<test>_<timestamp>/ directory.

For reset, the script sends a partial frame and keeps reception alive while
waiting up to 30 seconds. Hold btnU, press Enter on the PC while still holding
btnU, then release it only when the script says transmission has stopped.
Wait one second and press Enter again. This prevents sender-tail bytes from
being interpreted as commands after reset. Reset timing is operator-attested;
the script does not instrument the board reset pin or internal cnn_start.
No new RTL/bitstream is needed for this checker.
