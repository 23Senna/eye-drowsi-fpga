# Windows GUI

`EyeDrowsinessControl` is a small WinForms front end for the existing Basys 3
host tools. It does not contain a second UART implementation and does not
modify FPGA, RTL, or ML files.

## What it does

- discovers available COM ports through `tools/uart_cli.py ports`;
- selects and previews an eye crop;
- opens the existing `eye_capture.py` camera utility;
- clears the previous `eye_dataset` session when camera capture starts;
- lets you stop the camera with the GUI button or the camera window Close/Q action;
- loads captured left/right eye crops into a multi-select list for FPGA classification;
- uploads an image and runs one FPGA inference;
- runs live eye detection at 10 FPS by uploading each captured left-eye crop
  sequentially over UART;
- runs one of the 16 images already stored in the FPGA ROM;
- displays the existing `RESULT` telemetry and host activity.

## Setup

Follow [the common setup and demo guide](../docs/GETTING_STARTED.md).
Use Python 3.12 `.venv-camera` with tools/requirements-live.txt; it includes
UART, OpenCV/MediaPipe and Pillow for manual images. The GUI prefers this
interpreter for both live and manual commands. Do not install a second OpenCV
wheel. An older .venv is optional for standalone UART use, not the live setup.

Build with .NET 8 SDK; run with a compatible Windows Desktop runtime:

```powershell
dotnet build windows-app/EyeDrowsinessControl.csproj -c Release
.\windows-app\bin\Release\net8.0-windows\EyeDrowsinessControl.exe
```

For manual images/ROM, the app invokes uart_cli.py; live mode runs one
persistent live_webcam.py process. Both use the board's PC ownership (SW9 up).

The app is intentionally located in its own folder. Building it produces
only `windows-app\bin` and `windows-app\obj`; the FPGA and ML flow remains
unchanged.

Camera workflow: click **Start camera capture**, press `SPACE` in the OpenCV
window to record crops, then press `Q`, close that window, or click
**Stop camera capture**. The resulting PNG files appear in the captured-images
list. Select one or more entries with Ctrl/Shift and click **Upload & classify**.
Each selected crop is uploaded sequentially with an automatically incremented
frame ID.

## Integrated live webcam (Reyn, validated configuration)

The **Start live 10 FPS** button now starts one persistent
`tools/live_webcam.py` process in `.venv-camera`. The old PNG-directory
upload loop is replaced by the tested latest-frame mailbox and persistent
UART connection. It uses camera index from the GUI, left eye, target 10 Hz,
Reyn eye+brow crop, padding 0.15, grayscale 24x24, contrast 60..235, and
vertical offset +0.10. No new FPGA bitstream is required.

Prepare `.venv-camera` with Python 3.12 and `tools/requirements-live.txt`
(see `integration/docs/LIVE_WEBCAM.md`). The GUI prefers that interpreter
for recorder/CLI too. Diagnostics is enabled for GUI live sessions: exact
eye crops and golden comparisons are saved locally in `build/live_sessions`.
Only eye crops are saved; full webcam frames are not recorded.

1. Close other camera/COM tools; program the existing UART-upload bitstream.
2. Reset btnU, keep SW9 up/SW13 down. Select COM6, camera index 0 and a frame ID.
3. Click **Start live 10 FPS**. This starts transmission once a face/crop
   and UART are ready; clicking Start confirms the board has been reset.
4. The OpenCV windows show live camera/ROI and the exact completed input.
   The GUI shows the FPGA class/warning, roundtrip, golden comparison and
   the 24x24 input for that completed result. It does not substitute EAR labels.
5. O/C/U in the OpenCV window annotate samples; SPACE pauses. On a gap/pause,
   wait UART idle, reset btnU, then click **Resume live** or press SPACE.
6. **Stop live detection**, Q or closing the preview stops the child and
   drains the current transaction. Closing the GUI requests the same stop.
   After ten seconds without exit the GUI terminates the child and records
   that a board reset is required. Stop does not clear a latched board warning.

Upload/ROM operations, camera recorder and port changes are blocked during
live ownership. The frame ID advances from actual completed results and
never wraps silently. The activity log contains the session path and errors.

Build with `dotnet build windows-app/EyeDrowsinessControl.csproj -c Release`.
This workstation also has an isolated SDK at `build/dotnet-sdk/dotnet.exe`.
The executable is `windows-app/bin/Release/net8.0-windows/EyeDrowsinessControl.exe`.
Host regression: `.venv-camera/Scripts/python.exe -m unittest discover -s tools -p "test_*.py"`.
GUI bridge smoke (mock backend, no camera/board):
`dotnet run --project tools/gui-smoke/GuiSmoke.csproj`.
