# Interface contract v1 — drowsiness CNN on Basys3

From the integration lead, 30 Oct 2026. **v1 follows the Python owner's model on Drive** (`eye-detection-1/
quantize_export.py`, export of 29 Oct). It replaces v0 (16×16, one conv). Please reply with OK or changes.

## Global rules

- Verilog-2001, one module per file, must pass Icarus (`iverilog -g2012`) and Vivado 2025.2.1 (`xc7a35tcpg236-1`).
- One clock, 100 MHz (`clk`). Synchronous, active-high `rst`.
- `start` / `done` are **1-cycle pulses**. ROMs and buffers have a **1-cycle registered read**.
- **FC class 0 = eye closed, class 1 = eye open** (Python `data.yaml`). Argmax tie → class 0 (numpy `argmax`).
  System signal `eye_state`: 1 = closed, 0 = open, i.e. `eye_state = (logit0 >= logit1)`.

## Network and integer arithmetic (must be bit-exact with `quantize_export.forward`)

| Step | Shape | Arithmetic |
|---|---|---|
| input | 1×24×24 | pixel uint8 0..255 (unsigned: multiply as `$signed({1'b0, pix})`) |
| conv1 3×3, 4 filters | 4×22×22 | `acc = b1[f] + Σ pix·w1` (int8 weights, int32 bias) |
| act + pool | 4×11×11 = **a1** | `clip(acc >>> 10, 0, 127)` (S1 = 10, floor shift), 2×2 max |
| conv2 3×3, 4→8 | 8×9×9 | `acc = b2[f2] + Σ a1·w2` |
| act + pool | 8×4×4 = **a2** (128) | `clip(acc >>> 7, 0, 127)` (S2 = 7), 2×2 max, **floor** (row/col 8 dropped) |
| FC | 2 logits | `logit[c] = bf[c] + Σ a2[k]·wf[c][k]`, k = ch·16 + r·4 + c |

Worst-case bounds from the exported weights: conv1 19 bit, conv2 18 bit, FC 20 bit → **24-bit signed
accumulators and logits** are enough. Golden logits of the 16 demo images are within ±19k.

## cnn_core (module `cnn_core`, file `cnn_core.v`)

| Port | Dir | Width | Meaning |
|---|---|---|---|
| `clk`, `rst` | in | 1 | |
| `start` | in | 1 | 1-cycle pulse; ignored while `busy` |
| `busy` | out | 1 | high from the cycle after `start` until (and including) `done` |
| `done` | out | 1 | 1-cycle pulse, result valid in this cycle |
| `eye_state` | out | 1 | 1 = closed (`logit0 >= logit1`); valid at `done`, held until next `start` |
| `logit0`, `logit1` | out | 24 signed | FC outputs (class 0 closed, class 1 open), held like `eye_state` |
| `img_addr` / `img_data` | out / in | 14 / 8 | Image ROM. Core drives `img_addr[9:0] = row*24 + col`; top level supplies `[13:10]` = slot |
| `w_addr` / `w_data` | out / in | 12 / 8 | Weight ROM, int8 |
| `b_addr` / `b_data` | out / in | 5 / 32 | Bias ROM, int32 |

`cnn_control.v` (integration, done) sequences everything with one MAC per cycle: **36,124 cycles ≈ 0.36 ms** per
image. It drives the ROM addresses above, an activation buffer (`act_rd_addr` / `act_wr_addr`, a1 at 0–483,
a2 at 512–639, 1 BRAM) and data-aligned strobes `layer, mac_en, mac_clr, mac_last, win_last, fc_class, argmax_en`
(see the header of `rtl/cnn_control.v`). The Conv / ReLU_pool / fc_layer blocks plug into those strobes.
`sim/tb_cnn_control.v` contains a behavioural datapath that already matches the Python golden for all 16 images —
use it as the reference for your RTL.

## Memories (`fpga/mem/`, one hex word per line, built by `scripts/gen_sim_data.py` from `mem/export/`)

| File | Depth × width | Address / order |
|---|---|---|
| `images.mem` | 16384 × 8 | `{slot[3:0], pix[9:0]}`, 16 slots × 1024 words (576 px + zero pad) — Python export as is |
| `weights.mem` | 580 × 8 | 0–35 conv1 `f*9+ky*3+kx` · 36–323 conv2 `36+f2*36+f1*9+ky*3+kx` · 324–579 FC `324+class*128+k` |
| `biases.mem` | 14 × 32 | 0–3 conv1 · 4–11 conv2 · 12–13 FC |
| `labels.mem` | 16 × 1 | ground-truth `eye_state` per slot (1 = closed) |
| `stub_logits.mem` | 16 × 48 | `{logit0, logit1}` golden, used by `cnn_core_stub` |
| `seq.mem` | 64 × 4 | slot order for sequence mode (only correctly classified slots) |

Python owner: keep exporting `export/conv1_w … fc_b.mem`, `images.mem`, `expected*.txt/.mem`, `params.txt` in the
current formats.

**Taking a new export (retrain, new images, new S1/S2)** — no RTL edits:
1. copy `conv1_w/b, conv2_w/b, fc_w/b.mem`, `images.mem`, `params.txt` → `fpga/mem/export/`;
   `expected.txt`, `expected_a1.mem`, `expected_a2.mem` → `fpga/sim/vectors/`;
2. `GEN=1 bash sim/run.sh` — rebuilds `mem/*.mem` and `rtl/model_params.vh` (`CNN_S1`, `CNN_S2`, `CNN_N_IMG`),
   checks the integer model against `expected*`, then runs every testbench;
3. rebuild in Vivado (`scripts/create_project.tcl`, `scripts/build.tcl`).
Up to 16 images are supported (unused slots are padded black). The generator stops with a clear message if the
network shape changes (filter counts, input size, layers) — that needs `cnn_control.v` / `weight_bias_rom.v` edits.
Slots 0 and 1 are the two misclassified test images (label open → predicted closed, and the reverse).

## Board I/O (Basys3)

| Control | Function |
|---|---|
| `btnU` | reset |
| `btnC` | run one inference (manual mode) |
| `SW[3:0]` | image slot 0–15 (manual mode) |
| `SW[10]` | sequence scan: slots 0, 1, …, 15 in order instead of `seq.mem`; display shows the eye result |
| `SW[11]` | sequence step: in sequence mode btnC advances one frame (no timer) |
| `SW[12]` | sequence slow: 1 frame per second instead of 100 ms |
| `SW[13]` | low-confidence hold (`|logit0 − logit1| < CONF_MARGIN` → keep previous eye state) |
| `SW[14]` | sequence mode: one frame of `seq.mem` every 100 ms + drowsiness rules |
| `SW[15]` | 7-segment shows the last latency in cycles (hex, 36124 = `8d1C`) |
| 7-segment | `----` no result · `OPEn` / `CLSd` eye state · `tirE` DROWSY · `SLEP` MICROSLEEP (sequence mode) |
| LEDs | `[3:0]` slot · `[4]` busy · `[5]` eye closed · `[6]` sequence mode · `[13:7]` PERCLOS bar · `[14]` DROWSY · `[15]` MICROSLEEP (blinks) |

Drowsiness rules = `python/drowsy_ref.py`: window 32 frames, DROWSY at ≥ 13 closed, back to AWAKE at ≤ 6,
MICROSLEEP after 8 closed in a row, ends after 10 open in a row.

## Settled by the Python export (were open in v0)
Requant = floor shift + clip [0,127] per layer (S1 = 10, S2 = 7) · FC bias in product scale (add directly) ·
`.mem` files come from the Python owner · 16 demo slots.

## Still open (TBD)
1. **CNN Control owner** — `cnn_control.v` is written and verified; do the CNN teammates build their datapath on its
   strobes, or bring their own control?
2. **Class order** — keep FC class 0 = closed (current, `eye_state = logit0 >= logit1`), or swap in Python?
3. **CONF_MARGIN** for the low-confidence hold (default 1024 logit units) — Python owner to suggest a value.
4. **Datapath split** — one shared MAC (what `cnn_control` assumes) vs. separate conv / fc MACs.

## Integration with the CNN team's core (30 Oct, repo `eye-drowsi-fpga`)

The team delivered `rtl/cnn_top.v` + `rtl/rom_weights.v` (sequential one-MAC, own ROMs incl. images).
`drowsiness_top` instantiates it directly (stub only with `USE_STUB`); their files are used from their repo, not copied.

| cnn_top port | Use in drowsiness_top |
|---|---|
| `clk`, `rst` (async) | system clock, `rst` from input_control |
| `start` | `cnn_start` pulse from drowsy_fsm |
| `img_base_addr[13:0]` | `{img_slot, 10'b0}` (slot × 1024) |
| `done` (1-cycle pulse) | `cnn_done` |
| `prediction` (1 = open) | `eye_state = ~prediction` (tie → closed, same as numpy argmax) |
| `logit0/1 [31:0]` | low-confidence check (32-bit in drowsy_fsm) |

Verified: `sim/tb_top_real.v` — all 16 slots bit-exact vs the golden logits, 64 sequence frames vs `drowsy_ref`.
Latency 75,826 cycles. Vivado at 100 MHz: WNS −6.58 ns (path inside `cnn_top`: `kr2` → `a1_idx` → `a1_mem` mux →
multiply → `acc2`, 23 levels) → system clock lowered to 50 MHz with an MMCM (`CLK_MHZ` in `drowsiness_top`).
Request to the CNN team: register the `a1_mem` / `img_mem` read (or the product) before the accumulate so the core
meets 100 MHz. `rtl/cnn_control.v` (BRAM-friendly, 1 MAC/cycle, 36,124 cycles) stays available as a reference.
