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

## 3. Hardware

```
basys3_wrapper ── btnR → rising-edge → start
      │          btnC → async reset
      │          SW[3:0] → img_base_addr = SW × 1024
      └── cnn_top ── sequential FSM, one MAC
            ├── LOAD  (576 px → img_mem)
            ├── CONV1 (Conv1 + ReLU + pool → a1_mem)
            ├── CONV2 (Conv2 + ReLU + pool → a2_mem)
            └── FC    (FC + argmax → logits/prediction)
      └── seven_seg_drive ── "----" while busy, "OPN " / "CLSD" when done
```

* The active RTL uses one multiply-accumulate datapath sequentially. A
  convolution tap is processed over multiple clocks; the same MAC is reused
  for every output position, filter, and layer.
* `rom_weights.v` reads the exported `.mem` files through synchronous ROM
  ports. The layer buffers are written one value at a time instead of being
  transferred as large packed vectors.
* This organization trades latency for lower parallel logic and is the
  intended baseline for Basys 3 resource usage. Vivado synthesis is still
  required to confirm BRAM/LUT/FF inference.
* `cnn_top` ports: `clk, rst (async, active-high), start, img_base_addr[13:0] → done, prediction, logit0, logit1 (signed 32)`.
* Weight ROMs are **synchronous-read**: data appears one clock after the address. This is exactly what the original design got wrong — see below.

## 4. Sequential one-MAC implementation

`cnn_top.v` is intentionally a sequential engine rather than a fully
unrolled behavioral network. It requests one ROM value, performs one MAC, and
advances its counters. This prevents the nested convolution loops from
becoming hundreds of parallel multipliers during synthesis. The old buggy
implementation remains in `rtl/legacy/cnn_top_original_buggy.v` for history.

## 5. Stand-alone pipelined blocks

`conv_pe.v` (parameter `NTAPS` 9 or 36, 2-clock latency, throughput 1 output per clock) and `relu_requant.v` (parameter `SHIFT`) were written as a faster, testable replacement for the sequential datapath. They pass their unit tests (`sim/unit/`) but `cnn_top.v` does not instantiate them. `conv_act.v` and `maxpool2x2.v` are older helper modules that nothing instantiates.

These pipelined blocks remain available for a later resource- and
timing-oriented implementation; they are not instantiated by the current
one-MAC baseline.
