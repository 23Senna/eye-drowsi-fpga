# Setup and run the integrated demo

Run commands in the team repository root. Use **Python 3.12** and a separate
`.venv-camera`; install Python 3.12 if `py -3.12` is unavailable. The older
`.venv` UART environment is optional.

## Host environment

```powershell
py -3.12 -m venv .venv-camera
.\.venv-camera\Scripts\python.exe -m pip install -r tools\requirements-live.txt
.\.venv-camera\Scripts\python.exe -m pip check
.\.venv-camera\Scripts\python.exe tools\live_webcam.py --check
.\.venv-camera\Scripts\python.exe -m unittest discover -s tools -p "test_*.py" -q
```

Install only the pinned opencv-contrib-python distribution, not a second
opencv-python wheel. Pillow supports PNG/JPEG uploads. Keep ML training
packages in a separate environment: [ml/README.md](../ml/README.md).

## FPGA build and programming

Requires Vivado with Artix-7 support (xc7a35tcpg236-1). The archived current
build used Vivado 2025.2; see [its evidence](reports/current_build_20261104/README.md).

```powershell
vivado -mode batch -source integration/scripts/build_uart.tcl
```

This creates unique build/uart_hw_<timestamp>/ output, checks setup/hold,
and writes drowsiness_top.bit. Program that bitstream through Hardware
Manager. The root basys3_wrapper bitstream does not provide this integrated
UART/live/buzzer flow. Rebuilding does not guarantee identical placement or
bitstream hashes. [Board guide](../integration/docs/VIVADO_BOARD_GUIDE.md).

## GUI demo

Install .NET 8 SDK to build. Running the framework-dependent executable
requires a compatible .NET 8 Windows Desktop runtime.

```powershell
dotnet build windows-app/EyeDrowsinessControl.csproj -c Release
.\windows-app\bin\Release\net8.0-windows\EyeDrowsinessControl.exe
```

1. Connect the programmed board and webcam; close competing camera/COM tools.
2. Reset **btnU**, keep **SW9 up / SW13 down**. SW8 can mute the buzzer.
3. Select the board COM port (recorded workstation: COM6; other PCs differ),
   camera index 0 and a starting frame ID, e.g. 12000.
4. Click **Start live 10 FPS**. This confirms board reset and starts sending
   when eye/UART are ready. Start camera capture is a separate file recorder.
5. OpenCV windows show live camera/ROI. The GUI shows the completed FPGA result,
   roundtrip and exact 24x24 input. Diagnostics saves eye crops under ignored
   build/live_sessions/; full webcam frames are not recorded.
6. Test open -> closed -> warning -> open. O/C/U in the OpenCV window annotate
   samples; they do not change FPGA predictions.
7. Stop live detection or Q drains the current transaction. On a gap/pause,
   wait UART idle, reset btnU and click Resume live. Host stop alone does not
   clear a board alarm.

Defaults: left eye, target 10 Hz, Reyn eye+brow crop, pad 0.15, contrast 60..235,
Y offset +0.10. IDs advance per completed result and stop at exhaustion.
[Current limitations](STATUS_AND_ISSUES.md).

## Same pipeline without GUI

```powershell
.\.venv-camera\Scripts\python.exe tools\uart_cli.py ports
.\.venv-camera\Scripts\python.exe tools\live_webcam.py --camera 0 --port COM6 --eye left --fps 10 --frame-id 12000 --roi-style reyn --crop-offset-y 0.10 --diagnostics
```

Press SPACE to start the standalone client. For a manual upload use
`tools/uart_cli.py --port COM6 upload --image <eye.png> --frame-id 12000`
with the same interpreter and a fresh ID. [Image protocol](../integration/docs/IMAGE_UPLOAD.md).

## Checks

Host tests are above. With Bash, Icarus Verilog/vvp and Python/NumPy:

```bash
bash run_sim.sh
bash integration/sim/run.sh
```

The integration shell runner selects 14 testbenches. Host/core/integration/
physical checks have different scopes; software tests do not establish
physical webcam accuracy or board timing. [CPU benchmark](../integration/docs/INFERENCE_BENCHMARK.md).
