# Active interface — integrated eye-state system

Reviewed 2026-11-04 against main e3ac7ea. The
[original v1 proposal and annotations](archive/INTERFACE_V1_20261030.md)
remain historical; cnn_control/cnn_core proposals do not describe the active
filter-parallel datapath.

## Top and clock/reset

Use integration/rtl/drowsiness_top.v, part xc7a35tcpg236-1. Default CLK_MHZ=100
uses the board oscillator directly; CLK_MHZ=50 is a legacy MMCM option.
btnU passes through input_control; active CNN rst is asynchronous active-high.
Normal source build is scripts/build_uart.tcl from the repository root path
`integration/scripts/build_uart.tcl`. UART is 1,000,000 baud 8N1 since 5 Nov (`UART_BAUD`; `build_uart.tcl <out> 115200` for a legacy build); SW9 selects ownership.

## CNN and arithmetic

| Interface | Contract |
|---|---|
| Module | rtl/cnn_top.v, EXTERNAL_INPUT parameter enables upload input |
| clk/rst/start | clk, asynchronous active-high rst; start is one cycle, issued only when ready |
| img_base_addr | 14-bit ROM slot base, slot * 1024 |
| external_image | selects external input for this inference when enabled |
| external_addr/data | 10-bit pixel read address, 8-bit unsigned pixel; one-clock synchronous-read contract |
| done | one-cycle completion pulse; result valid at completion |
| prediction | 1=OPEN iff logit1 > logit0, else 0=CLOSED |
| logit0/logit1 | signed 32-bit; class 0=CLOSED, class 1=OPEN |

Input 1x24x24 uint8 -> valid Conv3x3 1->4 -> shift10/ReLU/clip0..127 ->
MaxPool2 (4x11x11) -> valid Conv3x3 4->8 -> shift6/ReLU/clip ->
MaxPool2 floor (8x4x4) -> FC128->2 -> argmax. Weights int8, biases int32;
flatten is channel*16 + row*4 + column. System eye_state reverses prediction:
1=CLOSED. Ties classify CLOSED. Low-confidence hold (SW13) can preserve a
previous temporal eye state; it does not change raw CNN logits.

ml/export/params.txt and weights/golden files define arithmetic. Change the
export only with shift/shape compatibility checks and regenerated vectors.
Run `GEN=1 bash integration/sim/run.sh` after an approved model update.
[Memory layout and CNN details](../../docs/ARCHITECTURE.md).

## Upload and result

[UART commands/ownership](UART.md) and [image upload](IMAGE_UPLOAD.md) are the
protocol source of truth. LOAD/RUN_FRAME use four hexadecimal ID digits;
replies report decimal IDs. Each valid image contains 576 row-major bytes
plus CRC-16/CCITT-FALSE. Invalid/partial uploads cannot run. Only one
transaction is outstanding; the live host keeps a latest-frame mailbox.
Telemetry contains source, slot, raw class, warning, signed logits, cycles,
integer us and uploaded frame_id. Integer us truncates cycles/CLK_MHZ:
702 cycles at 100 MHz = 7.02 us, transmitted as us=7 (5 Nov core; 7,996 / us=79 before).

## Board and temporal rules

| Control | Integrated behavior |
|---|---|
| btnU / btnC | reset / manual inference or sequence step |
| SW3:0 / SW9 | ROM slot / board-down or PC-up ownership |
| SW10 / SW11 / SW12 | sequence scan / step / slow |
| SW13 / SW14 / SW15 | confidence hold / sequence / latency in decimal microseconds |
| SW6 / SW7 / SW8 | buzzer test / type / mute |
| JA1 | active-low buzzer output; [buzzer guide](BUZZER.md) |

Temporal reference: integration/scripts/drowsy_ref.py. Window 32 observations,
DROWSY at >=13 closed and recovery at <=6, MICROSLEEP after 8 consecutive
closed and recovery after 10 consecutive open. These are observation counts,
not sensor-time measurements. Live gaps require UART idle then operator reset;
FPGA warnings may persist while host sending is paused.

## Host boundary and evidence

The Windows GUI uses tools/live_webcam.py with MediaPipe crop on the laptop;
FPGA receives preprocessed pixels, not camera video. Default live settings and
stop/resume procedures: [setup guide](../../docs/GETTING_STARTED.md).
No GUI EAR heuristic substitutes for the FPGA CNN/temporal result.
[Current results and build evidence](../../docs/STATUS_AND_ISSUES.md).
