# CNN eye-state accelerator on Basys 3

Group 3 KCCI FPGA project: integer CNN inference and observation-count
closure warning on the Basys 3 (Artix-7 xc7a35tcpg236-1).

**Start with [setup and demo](docs/GETTING_STARTED.md) and
[current status/limitations](docs/STATUS_AND_ISSUES.md).**

## System

```text
Webcam -> Laptop: MediaPipe -> eye/brow crop -> grayscale 24x24 -> contrast
       -> UART image upload -> FPGA: CNN -> OPEN/CLOSED -> warning FSM
       -> UART result -> Windows GUI/OpenCV preview, board LEDs/display/buzzer
```

The FPGA also retains 16 ROM test slots and board sequence modes. Camera
localization/preprocessing runs on the laptop; there is no direct camera
sensor interface on the FPGA. The model is
`24x24 u8 -> Conv3x3x4 -> ReLU(>>10, sat 127) -> MaxPool2 -> Conv3x3x8 ->
ReLU(>>6, sat 127) -> MaxPool2 -> FC 128->2 -> argmax`.
[Architecture](docs/ARCHITECTURE.md), [active interface](integration/docs/INTERFACE.md).

## Results and evidence

| Measurement | Result | Configuration / evidence |
|---|---|---|
| CNN latency | 7,996 cycles = **79.96 us at 100 MHz** | Filter-parallel 4/8/2 lanes; UART integer us field truncates to 79 |
| FPGA resources | 2,376 LUT, 2,230 FF, 7.5 BRAM, 14 DSP | drowsiness_top + real CNN + UART/upload + buzzer; 9dac154, Vivado 2025.2, build uart_hw_20261104_131740 |
| Routed timing | Setup +0.948 ns, hold +0.067 ns | [Raw reports and input hashes](docs/reports/current_build_20261104/README.md); all 29 recorded build-input hashes match reviewed main e3ac7ea |
| RTL/golden | 16/16 exported logit pairs identical; 14/16 labels correct | Recorded regressions; slots 0/1 are known model misses |
| Host/GUI | 30 host tests, Release GUI build and mock bridge smoke pass | [Selected evidence](docs/reports/current_build_20261104/README.md); operator reports physical integrated GUI passed |
| CPU baseline | CPU median 152.8 us; FPGA 79.96 us; **1.911x** | [Exact integer NumPy baseline](integration/docs/INFERENCE_BENCHMARK.md), Ryzen 9 5900HS, Balanced; not an optimized INT8-runtime comparison |
| Exported model accuracy | train 97.23%, valid 94.44%, test 98.15% (108 images) | Prior recomputation from committed export/crops; small single-subject evaluation with possible frame leakage |

These are CNN compute times, not webcam/serial/display latency. Different
historical builds have different resource/timing results; use the
[evidence index](docs/reports/README.md). Dataset accuracy does not establish
performance on unseen people. Live target 10 Hz is not guaranteed throughput;
Frame ID exhaustion and manual gap recovery remain documented limitations.

## Run

Follow [one host setup and board/GUI checklist](docs/GETTING_STARTED.md).
The camera environment is Python 3.12 `.venv-camera`; Windows GUI builds
with .NET 8. Full integrated bitstream build:

```powershell
vivado -mode batch -source integration/scripts/build_uart.tcl
```

This uses `integration/rtl/drowsiness_top.v`. The root
`vivado/create_project.tcl` and `rtl/basys3_wrapper.v` form a separate
standalone CNN demo; its controls/bitstream are not the integrated GUI flow.

## Repository map

| Path | Role |
|---|---|
| rtl/, sim/, run_sim.sh | CNN, layers, numerical tests |
| ml/ | Training/export scripts, compact crops, weights/golden outputs; [ML instructions](ml/README.md) |
| integration/ | Active board top, UART, temporal rules, buzzer, XDC/Tcl, integrated tests |
| tools/ | UART CLI, live capture/transport, diagnostics, benchmark and host tests |
| windows-app/ | WinForms front end using the persistent live client; [GUI details](windows-app/README.md) |
| docs/ | Current status/setup/architecture, dated journal, archived evidence |
| examples/ | Separate digit CNN learning reference |

[UART](integration/docs/UART.md) · [Image upload](integration/docs/IMAGE_UPLOAD.md)
· [Live client](integration/docs/LIVE_WEBCAM.md) · [Buzzer](integration/docs/BUZZER.md)

## Verification and contributions

With Bash, Icarus Verilog/vvp and Python/NumPy, run `bash run_sim.sh` and
`bash integration/sim/run.sh`. Host tests and GUI smoke commands are in
[the setup guide](docs/GETTING_STARTED.md). Software and hardware evidence
are labelled separately. Small vectors/model exports/reports are deliberate
artifacts; build caches and personal inputs are excluded. See
[repository policy](docs/REPOSITORY_POLICY.md).

## Team

Roles summarised from the daily progress reports (29 Oct – 3 Nov 2026).

| Member | Role |
|---|---|
| Michael Reynaldi Tamara ("Reyn") | ML model: dataset, training, int8/fixed-point export; live camera input (OpenCV) |
| Handy Jonarta | CNN core architecture (parallel layers, 100 MHz), CNN core layers + layer testbenches (with Nabil), block diagrams |
| Nabil Karim Abdurrahman | CNN core layers + layer testbenches (with Handy), GitHub |
| Karunia Muda Kurniawan ("Karan") | UART: result output and image upload |
| Bramantio Ananda ("Tio") | Top-level integration (input control, drowsy FSM, alert/display), FPGA implementation (XDC, Vivado, board test), top-level testbenches |

## License and attribution

- **Dataset:** Roboflow project `eye-detection-spucg-tdc0s` v1, licensed
  **Public Domain** (see `ml/data.yaml`).
- **Code:** No license has been selected yet. Add a `LICENSE` file before
  publishing or redistributing the code.
