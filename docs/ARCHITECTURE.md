# Architecture

## 1. Model

| Stage | Op | Output shape | Notes |
|---|---|---|---|
| input | grayscale crop, `uint8` | 1×24×24 | 576 px, no normalisation in RTL (scale 1/255 is folded into the quantised bias) |
| conv1 | 4 filters 3×3, `int8` weights, `int32` bias, valid | 4×22×22 | accumulate in 32 bit |
| act1 | `clip(acc >>> 10, 0, 127)` | 4×22×22 | ReLU + requantise (shift **S1 = 10**) |
| pool1 | 2×2 max | 4×11×11 | |
| conv2 | 8 filters 3×3×4 | 8×9×9 | |
| act2 | `clip(acc >>> 6, 0, 127)` | 8×9×9 | shift **S2 = 6** |
| pool2 | 2×2 max, floor | 8×4×4 | last row/col dropped (9 → 4) |
| fc | 128 → 2, `int8` weights | 2 logits (`int32`) | flatten order `ch*16 + row*4 + col` |
| decision | `logit1 > logit0` → **open (1)**, else **closed (0)** | | ties → closed |

Classes (from `ml/data.yaml`): `0 = eye_closed`, `1 = eye_open`.
Float model: `ml/train.py` (Conv 1→4, Conv 4→8, FC 128→2; Adam 5e-3, 80 epochs, random horizontal flip).
Quantisation: `ml/quantize_export.py` — per-tensor symmetric int8 weights; shifts S1/S2 chosen so the 99.9th percentile of positive accumulators fits in 7 bits; the Python integer model there is the *golden model* the RTL must match bit-exactly.

## 2. ROM / memory contents (`ml/export/`)

| File | Content | Layout |
|---|---|---|
| `conv1_w.mem` / `conv1_b.mem` | 36 × int8 / 4 × int32 | `[filter][row][col]` |
| `conv2_w.mem` / `conv2_b.mem` | 288 × int8 / 8 × int32 | `[f2][f1][row][col]` |
| `fc_w.mem` / `fc_b.mem` | 256 × int8 / 2 × int32 | `[class][ch*16+row*4+col]` |
| `images.mem` | 16 test images × 1024 bytes (576 used, rest `00`) | selected by `SW[3:0] × 1024` |
| `expected_a1.mem`, `expected_a2.mem` | golden intermediate maps for the 16 images (4×11×11, 8×4×4) | used by unit tests |
| `expected.txt` | golden label / prediction / both logits for the 16 images | used by `run_sim.sh` |
| `params.txt` | `S1=10`, `S2=6` | |

The 16 demo images are chosen by `quantize_export.py`: the first two are the model's misclassified test images (so **demo images 0 and 1 are expected to be wrong**), the remaining 14 alternate closed/open.

## 3. Active integrated system

`integration/rtl/drowsiness_top.v` instantiates the CNN, UART/upload staging
RAM, temporal FSM, board controls/display and buzzer. The host captures and
localizes the selected eye, crops/resizes/remaps contrast, then sends 576
uint8 pixels. GUI results are FPGA decisions; recorder EAR indicators are a
separate host heuristic. See [active interface](../integration/docs/INTERFACE.md).

## 3a. Standalone CNN wrapper (separate board demo)

```
basys3_wrapper ── btnR → rising-edge → start
      │          btnC → async reset
      │          SW[3:0] → img_base_addr = SW × 1024
      └── cnn_top ── sequencing FSM + img/a1/a2 buffers (synchronous reads)
            ├── LOAD  (576 px → img_mem)
            ├── conv1_layer (mac_pipe + relu_requant S1 + maxpool2x2 → a1_mem)
            ├── conv2_layer (mac_pipe + relu_requant S2 + maxpool2x2 → a2_mem)
            └── fc_layer    (mac_pipe, FC + argmax → logits/prediction)
      └── seven_seg_drive ── "----" while busy, "OPN " / "CLSD" when done
```

* Each layer has its own pipelined multiply-accumulate lanes (`mac_pipe`):
  conv1 computes 4 filters in parallel, conv2 computes 8 filters in parallel,
  and FC computes both classes in parallel. The layers still run one after the
  other (7,996 cycles per image, 80 µs at 100 MHz); parallel lanes reduce
  the number of taps per output rather than changing the layer sequencing.
* `rom_weights.v` reads the exported `.mem` files through synchronous ROM
  ports and packs all filter/class lanes for the current tap into one word
  (`conv1=32`, `conv2=64`, `fc=16` bits). The layer buffers are written one
  value at a time instead of being transferred as large packed vectors.
* The img / a1 / a2 buffers are read synchronously (one clock after the
  address), so Vivado maps them to block RAM and the core meets 100 MHz:
  current integrated build: setup +0.948 ns, hold +0.067 ns, 2,376 LUT /
  2,230 FF / 7.5 BRAM / 14 DSP (9dac154, Vivado 2025.2, 4 Nov).
  [Exact build evidence](reports/current_build_20261104/README.md).
  The 601 LUT / 3 DSP / +2.385 ns figures belong to the older 2 Nov design.
* `cnn_top` ports include `clk, rst` (async active-high), `start`,
  `img_base_addr[13:0]`, `external_image`, `external_addr[9:0]`,
  `external_data[7:0]`, `done`, `prediction`, signed 32-bit `logit0/1`.
  External input is enabled by parameter EXTERNAL_INPUT in the integrated top.
* Weight ROMs are **synchronous-read**: data appears one clock after the address. This is exactly what the original design got wrong — see below.

## 4. Pipelined layer implementation

`cnn_top.v` is a structural top: it loads the image, owns the three buffers
and starts `conv1_layer`, `conv2_layer` and `fc_layer` in turn. Each layer
pipelines address generation, the synchronous buffer/ROM read and the MAC
(`mac_pipe`), so one tap is accumulated per clock without hundreds of
parallel multipliers. The requant shift is a parameter of each layer's
`relu_requant` and must equal `S1` / `S2` in `ml/export/params.txt`
(`integration/scripts/gen_sim_data.py` checks this). The earlier sequential
one-MAC `cnn_top` (75,826 cycles, 50 MHz only) is in git history; the original
buggy version stays in `rtl/legacy/cnn_top_original_buggy.v`.

## 5. Stand-alone pipelined blocks

`relu_requant.v` (parameter `SHIFT`) and `maxpool2x2.v` are used inside
`conv1_layer` / `conv2_layer`. `conv_pe.v` (parameter `NTAPS` 9 or 36, 2-clock
latency, throughput 1 output per clock) passes its unit tests (`sim/unit/`)
but is not instantiated; `conv_act.v` and `mac_unit.v` are unused helpers.
