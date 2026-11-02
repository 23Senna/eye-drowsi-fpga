# CNN Eye-State (Drowsiness) Classifier on Basys 3 FPGA

A small, fully integer CNN that classifies a 24 × 24 grayscale eye crop as
**open** or **closed**. The design is implemented in Verilog for the Digilent
**Basys 3** (Artix-7 `xc7a35tcpg236-1`).

This is the final project for **FPGA KCCI Training (Training VLSI) – Group 3**.
The motivating use case is driver-drowsiness detection for ADAS.

> **Scope:** The FPGA classifies pre-cropped, pre-stored eye images. The board
> contains 16 test images in ROM, selected with switches. It does not provide
> camera input, face detection, or eye localisation. See
> [`docs/STATUS_AND_ISSUES.md`](docs/STATUS_AND_ISSUES.md) before quoting
> performance figures.

## Pipeline

```text
Roboflow eye dataset
  └─ ml/prepare_data.py
       └─ 24 × 24 crops (.npz)
            └─ ml/train.py (PyTorch, floating point)
                 └─ ml/quantize_export.py (int8 weights, golden outputs, .mem)
                      └─ rtl/ (Verilog CNN, ROMs loaded from .mem)
                           └─ Basys 3
```

Network: `24 × 24 u8 → Conv3×3×4 → ReLU(>>10, sat 127) → MaxPool2 →
Conv3×3×8 → ReLU(>>7, sat 127) → MaxPool2 → FC 128→2 → argmax`.
See [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) for the full data layout
and hardware details.

## Results at a glance

| Item | Result | How obtained |
|---|---|---|
| int8 model accuracy | train 97.2% · valid 94.4% · **test 98.1%** (108 images) | Recomputed from `ml/export/*.mem` and `ml/*.npz` with the bit-exact NumPy model |
| RTL vs. golden model | **16/16 logit pairs identical** (`rtl/cnn_top.v`) | Icarus Verilog via `./run_sim.sh` |
| Unit tests | All pass with 0 errors | `./run_sim.sh` |
| Latency | Approximately 75.8k cycles/image | Sequential one-MAC datapath; measured by simulation |
| Resources | 5,063 LUT (24%), 9,858 FF (24%), 5 BRAM, 0 DSP | Historical Vivado 2024.2 reports; re-synthesis required |
| **Timing at 100 MHz** | **Not yet verified after the one-MAC restoration** | Run synthesis and implementation again |

> **Evaluation caveat:** The test set is small and all samples come from one
> subject. Treat the 98.1% test accuracy as optimistic; see the issues document
> for details.

## Repository layout

```text
├── README.md
├── run_sim.sh                  # Runs all simulations and checks golden outputs
├── rtl/
│   ├── basys3_wrapper.v        # FPGA top: buttons, switches, LEDs, 7-segment
│   ├── cnn_top.v               # Sequential FSM and one-MAC datapath
│   ├── rom_weights.v           # Synchronous .mem ROMs
│   ├── seven_seg_drive.v       # Displays OPN / CLSD / ----
│   ├── conv_pe.v, relu_requant.v
│   ├── conv_act.v, maxpool2x2.v # Helper modules
│   └── legacy/cnn_top_original_buggy.v
├── sim/
│   ├── tb_cnn.v                # Top-level testbench for 16 images
│   ├── unit/                   # Unit testbenches and vector generator
│   └── unit_vectors/           # Reference test vectors
├── constraints/basys3.xdc
├── vivado/create_project.tcl   # Recreates the Vivado project
├── ml/                         # Data preparation, training, and exports
├── docs/
│   ├── ARCHITECTURE.md
│   ├── STATUS_AND_ISSUES.md
│   ├── reports/
│   └── team/
├── integration/                # Drowsiness top level for the board (see integration/README.md)
└── examples/digits-demo-basys3 # Separate 8 × 8 digit CNN reference demo
```

## Quick start

### 1. Run the simulations

No Vivado installation is required. Install `iverilog`, `python3`, and
`numpy`, then run from the repository root:

```bash
./run_sim.sh
```

The expected final line is `ALL TESTS PASSED`.

The Vivado testbench also compares every prediction with the labels in the
exported test set and prints `CORRECT` or `WRONG` for each image, followed by
the classification total. Images 0 and 1 are intentionally included model
misses, so the expected result is `14 / 16`.

### 2. Retrain and re-export (optional)

The committed files in `ml/` are sufficient to reproduce the exported model.
Run the following commands from the `ml/` directory:

```bash
pip install -r requirements.txt
python train.py
python quantize_export.py
```

The raw Roboflow images and labels are not included in this repository.
`prepare_data.py` therefore requires a separately downloaded dataset. See
[`ml/README.md`](ml/README.md) for the expected directory structure and file
formats.

### 3. Create the Vivado project

Vivado 2024.2 was used for the existing reports. From the repository root:

```bash
vivado -mode batch -source vivado/create_project.tcl
```

Open the generated project, then run synthesis, implementation, and bitstream
generation. Check timing first: the current design does not meet 100 MHz, and
the existing Vivado resource reports were produced before the RTL fix.

#### Vivado simulation top levels

Vivado has two different top-level settings:

| Setting | Correct value for this eye project |
|---|---|
| **Design top** (`sources_1`) | `basys3_wrapper` |
| **Simulation top** (`sim_1`) | `tb_cnn` from `sim/tb_cnn.v` |

`tb_cnn` instantiates `cnn_top` and checks all 16 stored eye images. Do **not**
use `tb_cnn_core`: that testbench belongs to the separate
[`examples/digits-demo-basys3`](examples/digits-demo-basys3) digit demo.

The simulation log should contain the eye-project testbench and files similar
to:

```text
tb_cnn.v
cnn_top.v
rom_weights.v
```

If the Vivado Sources panel shows `examples/digits-demo-basys3` or
`tb_cnn_core`, close that project and create a clean one using
`vivado/create_project.tcl`. For an existing project, the equivalent Tcl
settings are:

```tcl
set_property top basys3_wrapper [get_filesets sources_1]
set_property top tb_cnn [get_filesets sim_1]
update_compile_order -fileset sources_1
update_compile_order -fileset sim_1
```

If synthesis reports:

```text
[Synth 8-4391] module 'rom_weights' not found
```

the open Vivado project does not contain the current ROM source, even if the
file exists on disk. In the Tcl Console, add it to the active design fileset
and refresh compile order:

```tcl
add_files -norecurse D:/project/cnn-eye-drowsiness-basys3/cnn-eye-drowsiness-basys3/rtl/rom_weights.v
update_compile_order -fileset sources_1
set_property top basys3_wrapper [get_filesets sources_1]
```

Then right-click **Synthesis** and choose **Reset Runs**, followed by **Run
Synthesis**. If the warning persists, close the project and run the complete
`vivado/create_project.tcl` script instead; do not keep adding duplicate
copies of `cnn_top.v` or `rom_weights.v`.

The project path in the simulation log must also point to this repository:
`D:/project/cnn-eye-drowsiness-basys3/cnn-eye-drowsiness-basys3`. A path
containing `eye-drowsi-fpga/eye-drowsi-fpga` indicates a different or copied
Vivado project.

### 4. Use the board

| Control | Function |
|---|---|
| `SW[3:0]` | Select one of the 16 stored test images |
| `btnR` | Start inference on the rising edge |
| `btnC` | Reset |
| 7-segment display | `----` while running, then `OPN ` (open) or `CLSD` (closed) |
| `LED0` | Prediction: `1` = open, `0` = closed |
| `LED14` | Start pulse |
| `LED15` | Done |

## Team

The roles below are taken from the 29 October 2026 daily report.

| Member | Role |
|---|---|
| Michael Reynaldi Tamara ("Reyn") | Python model, dataset, and weight generation |
| Handy Jonarta | Architecture design |
| Bramantio Ananda ("Tio") | Architecture design and topic |
| Karunia Muda Kurniawan ("Karan") | Dataset and GitHub environment |
| Nabil Karim Abdurrahman | Role not listed in the report |

## License and attribution

- **Dataset:** Roboflow project `eye-detection-spucg-tdc0s` v1, licensed
  **Public Domain** (see `ml/data.yaml`).
- **Code:** No license has been selected yet. Add a `LICENSE` file before
  publishing or redistributing the code.
