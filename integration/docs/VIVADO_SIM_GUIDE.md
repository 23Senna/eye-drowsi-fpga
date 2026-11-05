# Running the testbenches in Vivado (behavioural simulation)

Project: any Basys3 project into which `scripts/add_sources.tcl` was sourced (it also runs `scripts/add_sim_sources.tcl`),
e.g. `integration/vivado/drowsiness.xpr` from `scripts/create_project.tcl` (Vivado 2025.2.1). Run `GEN=1 bash sim/run.sh`
once before (it makes `sim/vectors/`). The 6 testbenches are then in **Simulation Sources → sim_1**; top = `tb_top_real`.
All 6 PASS (30 Oct).

> Note (5 Nov): the 3bf6c36 core takes 702 cycles = 7 µs (4 Nov: 7,996 cycles = 80 µs); absolute times in the tables
> below were measured with the old 37,290-cycle core, so later events now happen earlier (parallel core (4 Nov)).

## 1. Open and run

1. Open Vivado from the Start menu → **Open Project** → your `.xpr`.
2. Left panel (Flow Navigator) → **SIMULATION → Run Simulation → Run Behavioral Simulation**.
   Compile + elaborate takes ~1 min, then it runs to the end by itself (`runtime = -all`).
   `tb_top_real` simulates **70.37 ms**, which takes a few minutes of real time.
3. When it stops, look at the **Tcl Console** (bottom). Expected lines:
   ```
   manual: 16 slots checked, 0 errors; cnn_top latency 7996 cycles (79 us)
   sequence: 64 frames checked (13 in MICROSLEEP), 0 errors total
   scan: 16 frames checked, 0 errors total
   PASS tb_top_real (cnn_top: 16 slots bit-exact, latency 7996 cycles)
   $finish called at time : 70368550 ns
   ```
   The testbench checks everything itself: if the last line says **PASS**, the design is correct.
   `FAIL ... @n` lines name the check and the slot / frame number.

## 2. Add the useful signals to the waveform

By default the wave window only shows the testbench pins (`clk sw btnC btnU led seg an`). xsim records only the
signals that are in the wave window, so add the internal ones and then run again. Paste this into the Tcl Console:

```tcl
add_wave -radix unsigned /tb_top_real/sw
add_wave /tb_top_real/btnC
add_wave -radix unsigned /tb_top_real/dut/img_slot
add_wave /tb_top_real/dut/cnn_start /tb_top_real/dut/cnn_done /tb_top_real/dut/frame_done
add_wave /tb_top_real/dut/eye_state
add_wave -radix dec /tb_top_real/dut/logit0 /tb_top_real/dut/logit1
add_wave -radix unsigned /tb_top_real/dut/latency
add_wave -radix unsigned /tb_top_real/dut/drowsy_state /tb_top_real/dut/closed_count /tb_top_real/dut/closed_run /tb_top_real/dut/perclos
add_wave -radix hex /tb_top_real/led
restart
run all
```
(Or with the mouse: **Scope** panel → expand `tb_top_real` → click `dut` → **Objects** panel → select signals →
right-click → *Add to Wave Window*; then toolbar **Restart** (⟲) and **Run All** (▶).)

Do **not** add signals inside `dut/u_core` (the CNN): they change every cycle for 70 ms and the waveform file gets huge.

Tips: **Zoom Fit** shows the whole run; `frame_done` / `cnn_start` are 1-cycle pulses, invisible when zoomed out:
select the signal and use **Go to Next Transition** (toolbar arrow) to jump between them.
`seg`/`an` are the multiplexed 7-segment pins and are hard to read in a waveform; the testbench decodes them for you.
Meaning of signals: `eye_state` 1 = closed, 0 = open; `drowsy_state` 0 AWAKE, 1 DROWSY, 2 MICROSLEEP;
LEDs `[3:0]` slot, `[4]` busy, `[5]` eye closed, `[6]` sequence mode, `[13:7]` PERCLOS bar, `[14]` DROWSY, `[15]` MICROSLEEP.

## 3. What happens when (tb_top_real, 100 MHz in simulation)

| Time | Part | What to look at |
|---|---|---|
| 0 – 0.1 µs | reset | `btnU` = 1 for 10 cycles |
| 0.7 µs → 5.99 ms | **1. manual mode** | `sw[3:0]` = 0..15, one `btnC` press each; `cnn_start` → 80.0 µs later `cnn_done` / `frame_done` |
| 5.993 – 5.994 ms | **2. latency view** | `sw[15]` = 1, display shows `0079` (µs); `latency` = 7996 |
| 5.994 → 57.57 ms | **3. sequence mode** | `sw[14]` = 1, one frame every 0.8 ms (64 frames, slots from `seq.mem`) |
| 57.57 → 70.37 ms | **4. scan mode** | `sw[10]` = 1 too, slots 0..15 in order, results = manual mode |
| 70.37 ms | end | `$finish`, PASS line |

### Part 1: one frame per slot (`frame_done` at 0.374 ms + n × 0.3745 ms)

`latency` is always **7996 cycles** (= 80.0 µs at 100 MHz, in simulation and on the board; the display shows `0079`).
`eye_state` = 1 when logit0 ≥ logit1. Values = Python golden (fixed-point export, S2 = 6); slots 0 and 1 are the
model's two misclassified test images (closed image → open, open image → closed):

| slot | frame_done (ms) | logit0 | logit1 | eye_state |
|---|---|---|---|---|
| 0 | 0.374 | 492 | 727 | 0 open |
| 1 | 0.748 | 828 | −1330 | 1 closed |
| 2 | 1.123 | 11912 | −12193 | 1 |
| 3 | 1.497 | −17106 | 17976 | 0 |
| 4 | 1.872 | 27235 | −25224 | 1 |
| 5 | 2.246 | −8710 | 10636 | 0 |
| 6 | 2.621 | 15108 | −15060 | 1 |
| 7 | 2.995 | −14964 | 16429 | 0 |
| 8 | 3.370 | 26956 | −25062 | 1 |
| 9 | 3.744 | −16890 | 18298 | 0 |
| 10 | 4.119 | 7759 | −7738 | 1 |
| 11 | 4.493 | −10288 | 12299 | 0 |
| 12 | 4.868 | 12267 | −11171 | 1 |
| 13 | 5.242 | −14681 | 16314 | 0 |
| 14 | 5.617 | 16936 | −16313 | 1 |
| 15 | 5.991 | −20662 | 21904 | 0 |

### Part 3: drowsiness states (the interesting part for the demo)

First frame at 7.17 ms, then every 0.8 ms. Watch `closed_count` (closed frames in the last 32), `closed_run`
(closed frames in a row) and `drowsy_state`:

| Time (ms) | Event | Rule |
|---|---|---|
| 7.17 – 34.37 | AWAKE (`drowsy_state` 0), `closed_count` slowly rises | |
| **35.17** | → **DROWSY** (1), `led[14]` on, display `tirE` | `closed_count` reaches 13 |
| **43.97** | → **MICROSLEEP** (2), `led[15]` blinks, display `SLEP` | `closed_run` reaches 8 |
| 46.37 | longest closed run = 11 | |
| **54.37** | → back to **DROWSY** (1) | 10 open frames in a row |
| 57.57 | end of sequence (state stays DROWSY through part 4) | |

### Part 4: scan
`img_slot` 0, 1, …, 15 at 57.99, 58.79, … 69.99 ms (`cnn_start`; `frame_done` 0.080 ms later, the last at 70.37 ms);
`eye_state` 0, 1, 1, 0, 1, 0 … exactly as in part 1.

## 4. The other testbenches

Simulation Sources → right-click a testbench → **Set as Top**, then Run Behavioral Simulation. Each prints one
`PASS`/`FAIL` line: `tb_input_control`, `tb_alert_control`, `tb_drowsy_fsm` (FSM vs Python `drowsy_ref`),
`tb_roms`, `tb_cnn_control`. Set `tb_top_real` back as top afterwards.

## 5. Disk space

Each run writes a waveform file `<project>.sim/sim_1/behav/xsim/<tb>_behav.wdb`. Close the simulation
and delete the `.wdb` files when done if C: is low. A testbench that hangs keeps growing this file (this filled C: once
with tb_drowsy_fsm, now fixed): if a run takes much longer than a few minutes, press **Break** (⏸) and check the console.
