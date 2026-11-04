# Live external webcam to FPGA

The new Python entry point combines the team's MediaPipe crop function with
the existing CRC upload protocol. It reads one selected eye per observation,
keeps one serial connection open and displays the camera, ROI, exact 24x24
input enlarged for inspection, and fresh FPGA results. PNG disk roundtrips
and one-process-per-image are not used in this live path.

## Environment

Use Python 3.12 with an isolated camera environment; the older pinned
MediaPipe FaceMesh API does not ship a CPython 3.14 wheel.

```powershell
py -3.12 -m venv .venv-camera
.\.venv-camera\Scripts\python.exe -m pip install -r tools/requirements-live.txt
.\.venv-camera\Scripts\python.exe tools/live_webcam.py --check
```

The local setup session can use the bundled Python 3.12 runtime to create
the same environment if py -3.12 is unavailable. The .venv-camera directory
is ignored and independent of the existing .venv UART environment. There
is only one OpenCV wheel (opencv-contrib-python); avoid installing a second
opencv-python wheel into this environment.

## Preview first

```powershell
.\.venv-camera\Scripts\python.exe tools/live_webcam.py --camera 0 --eye left --preview-only
```

If opening fails, try --camera 1 or --backend msmf. The camera index is an
OpenCV index, not the device name. Left/right means the person's own eye,
as in eye_capture.py; the preview is not mirrored. Press Q or close the
main camera window to quit. This mode never opens a COM port.

## Live FPGA mode

Program an image-upload-capable bitstream. Current parallel firmware reports
7996 cycles / 79 us; older image-upload firmware reports 37290 / 372. The
live client accepts either numerical timing rather than hardcoding latency.
Close the Windows GUI or serial terminal using the same COM port.

```powershell
.\.venv-camera\Scripts\python.exe tools/live_webcam.py --camera 0 --port COM6 --eye left --fps 10 --frame-id 1000
```

1. Keep SW9 up and SW13 down. Reset the board with btnU while sending is paused.
2. Wait for the green eye rectangle, then press SPACE in the main window.
3. Observe the eye class, warning and CNN latency. Console/log intervals show
   actual cadence and UART roundtrip; target 10 Hz is not a measured guarantee.
4. SPACE pauses; an accepted in-flight transaction may finish. Wait until it
   drains before resetting the board. Q exits and drains the serial worker.

No face/crop sends no observations. A gap longer than --max-gap (default
0.5 s) pauses inference and invalidates the on-screen fresh result. Before
resuming, wait for UART to finish, press btnU, then SPACE. Resume is manual
operator confirmation of reset; there is no reset command/readback in the
current UART protocol. The physical board alarm can persist while paused
or after quitting, until btnU/reset or new valid observations clear it.

A UART error stops transmission without automatic retries. Stop the app,
reset the board with no sender running, and restart. IDs increase and the
worker stops at exhaustion. Choose a fresh initial ID if not resetting first.

## Scheduling and evidence

Capture and MediaPipe run on the preview thread. A separate UART worker uses
a latest-frame mailbox (one entry); slow transmission replaces queued frames
instead of accumulating video delay. The worker sends at most the configured
rate and never reuses an already consumed capture. Crops older than 250 ms
are discarded. Only one upload/inference/result transaction is outstanding.

Preprocessing reuses eye_capture.crop_eye: BGR -> grayscale, landmarks ->
eye-and-brow square with 15% margin, OpenCV INTER_AREA -> 24x24 uint8,
then Reyn's contrast remapping to 60..235 (default --roi-style reyn). Pixels
are sent directly as 576 bytes to uart_cli.run_image. MediaPipe finds the ROI;
OPEN/CLOSED and warning labels in FPGA mode come from the FPGA result.

Session events go to build/live_sessions/<unique timestamp>/events.jsonl:
camera/port configuration, observation sequence and frame ID, host monotonic
capture/send/result timestamps, capture intervals, roundtrip, result age,
replaced frames, face availability, operator toggles and errors. Images and
video are not recorded by default. The capture timestamp marks host read
completion, not the sensor's exposure timestamp. Serial roundtrip includes
transfer, inference, acknowledgements and output; cycles/us only measure CNN.

The FPGA still uses an observation-count temporal FSM. Do not send both eyes
independently into that same history, invent frames for a gap, or interpret
an irregular stream as calibrated closure duration. The selected eye stays
fixed for the session; changing subjects/eye/session requires a reset.

## Checks

Host tests: python -m unittest discover -s tools -p 'test_*.py' -v.
Mailbox and transport tests cover freshness/replacement, no replay, persistent
port lifetime, IDs and stop-on-error. The portable RTL runner now includes
buzzer_control so tb_top and other integrated cases can elaborate.

Physical acceptance: verify camera index/ROI, run a stationary OPEN/CLOSED
sequence, compare selected uploaded pixel frames against an integer golden
if required, check cadence/roundtrip, unplug camera or hide face to observe
pause, reset/resume, and verify no stale label is presented as current.
Host tests alone do not establish live hardware performance.

## Diagnose an incorrect class

Add --diagnostics to save the exact 576-byte payload for each inferred frame
under that session's inputs/ directory and compute integer golden logits
using the committed export. Only eye crops are saved, with explicit opt-in;
the original full camera frame is not stored. Results still come from FPGA.
The result overlay includes frame ID and a separate window shows the crop
for that specific completed result. The ordinary crop window shows the latest
camera crop, which can be newer than the classified observation.

Press O to mark subsequent observations visually OPEN, C for CLOSED and U
to remove the label. These are operator ground-truth annotations, never
substitutes for the FPGA prediction. Ignore transition frames while eyelids
are moving when assessing accuracy. GOLDEN MATCH with a wrong visual class
points toward model/preprocessing/generalization; GOLDEN MISMATCH stops the
sender and retains exact pixels for transport/RTL/firmware investigation.

The --pad option controls crop context; legacy default 0.35 is unchanged. Do not
tune crop/thresholds against unlabelled examples or force CLOSED from landmarks.
Collect stable labelled samples first. Actual throughput display now averages
recent send timestamps rather than showing inverse single-capture intervals.

## Reyn preprocessing on the UART path

The Windows GUI's Start live 10 FPS now launches this same client with
--gui-control and the validated settings. START/STOP commands arrive on stdin;
LIVE_EVENT-prefixed JSON on stdout carries results/state/session metadata.
EOF requests STOP. GUI stop/close drains the current transaction; an idle
gap can be resumed only after the operator resets the board. OpenCV retains
the live camera/ROI windows; the GUI shows exact completed input and FPGA
results. See windows-app/README.md for the operator checklist.

The live default is now --roi-style reyn. It calls the same crop_eye_brow
function as the recorder, includes the eyebrow landmarks, uses padding 0.15
and applies reduce_contrast exactly once after resize. Those resulting 576
bytes go directly to the UART worker without another image conversion.
For more lower-eye context, live reyn mode shifts the square down by 10%
of its side (--crop-offset-y 0.10). The square size stays the same. Positive
values move down, negative values move up; 0 restores the original Reyn
position. Phone/legacy and the standalone recorder default to zero shift.
The offset is logged and shown as Y +0.10 in the preview.
The diagnostic golden and saved raw inputs also use these adjusted bytes.
Preview/startup and session metadata identify the ROI, padding and contrast.

```powershell
.\.venv-camera\Scripts\python.exe tools\live_webcam.py --camera 0 --port COM6 --eye left --fps 10 --frame-id 10000 --roi-style reyn --diagnostics
```

Close the previous sender, reset btnU with UART idle, keep SW9 up/SW13 down,
then start the new client and press SPACE. Use O/C/U to annotate observations.
EAR labels/timers from the recorder do not replace FPGA decisions: the live
OPEN/CLOSED and warning continue to come from the FPGA CNN and temporal FSM.
No new bitstream is required. Host tests verify adjusted payload preservation;
visual accuracy with the actual webcam still needs a physical trial.

## Earlier phone-style crop experiment

The standalone eye_capture.py recorder now incorporates Reyn's eye-plus-brow
crop (15% margin), contrast compression to 60..235, and six-point EAR panel.
Run `.\.venv-camera\Scripts\python.exe eye_capture.py --camera 0 --out-dir local_inputs/reyn_capture`.
SPACE records labelled crops, +/- adjusts EAR threshold, Q exits. OPEN/CLOSED
filename labels and AWAKE/DROWSY/SLEEPING in that recorder are laptop EAR
heuristics (0.21 threshold, both eyes closed for 0.7/1.5 seconds), not FPGA
predictions or verified ground truth. The UART live client now shares the
recorder's crop and contrast in reyn mode, while retaining FPGA classification.

Select --roi-style phone to approximate the framing of
the successful manual phone crops. This selects a square 1.90 times the eye-corner distance
(--pad 0.90), centered 0.16 eye widths above the corner midpoint and 0.10
eye widths outward. Using corners keeps the center independent of eyelid
opening. Explicit --pad overrides the preset width; --roi-style legacy
retains the original crop. Both modes still produce 24x24 grayscale bytes.
The active style and width appear in the terminal and live preview. The phone
square is about 41% wider than the legacy 1.35-eye-width square, including
more eyebrow and surrounding skin. Phone and legacy modes do not remap
contrast; only reyn mode shares the recorder's 60..235 compression.

Example (after stopping the previous sender, waiting for UART idle and resetting):

```powershell
.\.venv-camera\Scripts\python.exe tools\live_webcam.py --camera 0 --port COM6 --eye left --fps 10 --frame-id 7000 --roi-style phone --diagnostics
```

The preset geometry was measured by registering three manual crops against
their original phone photos; the fourth did not have sufficient matching
features. On these same originals, integer-reference inference classified
both OPEN eyes correctly in either automatic mode. Both CLOSED eyes were
misclassified by legacy cropping and correctly classified with phone-style
cropping. This is a calibration comparison on reused photos, not independent
webcam validation. Private images/comparisons stay under ignored local_inputs/.
No model weights, thresholds or FPGA bitstream change is required.

For live validation press SPACE to start, O for a stable OPEN interval,
C for a stable CLOSED interval, then O again (at least three seconds each).
Exclude transition frames. Inspect the input for the completed result and
retain the diagnostic session for accuracy/golden comparison.
