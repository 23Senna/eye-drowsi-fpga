# Integration — drowsiness top level for Basys3

Board top level around the CNN core of this repo (`rtl/cnn_top.v` + `rtl/rom_weights.v`, used as is, not copied):
buttons/switches, the drowsiness state machine (PERCLOS window, DROWSY / MICROSLEEP alarms), 7-segment and LED
output, a 50 MHz system clock (MMCM), simulation and Vivado scripts.

```text
integration/
├── rtl/
│   ├── drowsiness_top.v    # FPGA top: MMCM 100 -> 50 MHz, input_control, drowsy_fsm, cnn_top, alert_control
│   ├── input_control.v     # btnU reset sync, btnC debounce + one-pulse, switch sync / debounce
│   ├── drowsy_fsm.v        # IDLE -> START_CNN -> WAIT_DONE -> UPDATE -> SHOW; drowsiness rules; sequence modes
│   ├── alert_control.v     # 7-segment OPEn / CLSd / tirE / SLEP / ---- / latency, LED patterns
│   ├── cnn_core_stub.v, image_rom.v, weight_bias_rom.v   # stub build (`USE_STUB`), golden logits
│   ├── cnn_control.v       # alternative 1-MAC/cycle sequencer (reference, verified, not used in the build)
│   └── model_params.vh     # generated: S1, S2, image count
├── sim/                    # Icarus testbenches + run.sh (tb_top_real = this top with the real cnn_top)
├── mem/seq.mem             # sequence-mode script (+ stub/test files)
├── scripts/                # gen_sim_data.py, drowsy_ref.py, add_sources.tcl, create_project.tcl, build.tcl
├── constraints/basys3.xdc  # pins for drowsiness_top
└── docs/                   # INTERFACE.md (contract), VIVADO_BOARD_GUIDE.md (step by step + board test)
```

## Quick start

```bash
bash integration/sim/run.sh                 # all testbenches (first run generates vectors from ml/export)
GEN=1 bash integration/sim/run.sh           # regenerate after a new ml/export
```

Expected: 7 × `PASS`; `tb_top_real` (~3 min) checks all 16 images bit-exact against `ml/export/expected.txt`,
64 sequence frames against `scripts/drowsy_ref.py` and the scan mode.

Vivado (GUI): open/create a Basys3 project, then in the Tcl console
`source {<repo>/integration/scripts/add_sources.tcl}` → Generate Bitstream → program.
Batch: `cd integration && vivado -mode batch -source scripts/create_project.tcl && vivado -mode batch -source scripts/build.tcl`.
Full guide and board test table: [docs/VIVADO_BOARD_GUIDE.md](docs/VIVADO_BOARD_GUIDE.md); Vivado simulator (6 testbenches in
sim_1): [docs/VIVADO_SIM_GUIDE.md](docs/VIVADO_SIM_GUIDE.md).

## Board controls

| Control | Function |
|---|---|
| btnU | reset |
| btnC | run one inference (manual) / next frame (sequence step mode) |
| SW[3:0] | image slot 0–15 |
| SW10 | sequence scan: slots 0, 1, …, 15 in order |
| SW11 | sequence step: btnC = next frame |
| SW12 | sequence slow: 1 frame per second |
| SW13 | low-confidence hold |
| SW14 | sequence mode (frames every 100 ms from `mem/seq.mem` + drowsiness rules) |
| SW15 | show latency in µs |

## Results (Vivado 2025.2.1, xc7a35tcpg236-1)

- `cnn_top` latency 75,826 cycles = 1.52 ms at 50 MHz.
- At 100 MHz `cnn_top` misses timing (WNS −6.58 ns; path `kr2` → `a1_idx` → `a1_mem` read → multiply → `acc2`,
  23 logic levels), so the system clock is 50 MHz: all constraints met (WNS ≈ +0.5–1.0 ns, WHS +0.12 ns).
  Registering the `a1_mem` / `img_mem` read in `cnn_top` should allow `CLK_MHZ = 100` in `drowsiness_top.v`.
- ~5.2k LUT, ~10.1k FF, 5 BRAM, 0 DSP.
