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
- runs one of the 16 images already stored in the FPGA ROM;
- displays the existing `RESULT` telemetry and host activity.

The application starts `tools/uart_cli.py` for every FPGA operation. It uses
`.venv\Scripts\python.exe` when that environment exists, otherwise it falls
back to `python` on `PATH`. The Basys 3 must be in PC ownership (`SW9` up)
for upload and ROM-slot commands.

## Run on Windows

Install the .NET 8 SDK and prepare the existing host environment from the
repository root:

```powershell
python -m venv .venv
.\.venv\Scripts\python.exe -m pip install -r tools\requirements-camera.txt
dotnet run --project windows-app\EyeDrowsinessControl.csproj
```

`tools\requirements-camera.txt` includes the existing UART dependency plus
NumPy, OpenCV, and MediaPipe 0.10.21 required by `eye_capture.py`. The
MediaPipe version is pinned because newer releases removed the legacy
`mp.solutions.face_mesh` API used by the existing capture utility. If the environment
already exists, install the missing camera packages with:

```powershell
.\.venv\Scripts\python.exe -m pip install -r tools\requirements-camera.txt
```

For PNG/JPEG upload, also install Pillow:

```powershell
.\.venv\Scripts\python.exe -m pip install -r tools\requirements-image.txt
```

The app is intentionally located in its own folder. Building it produces
only `windows-app\bin` and `windows-app\obj`; the FPGA and ML flow remains
unchanged.

Camera workflow: click **Start camera capture**, press `SPACE` in the OpenCV
window to record crops, then press `Q`, close that window, or click
**Stop camera capture**. The resulting PNG files appear in the captured-images
list. Select one or more entries with Ctrl/Shift and click **Upload & classify**.
Each selected crop is uploaded sequentially with an automatically incremented
frame ID.
