# Vivado + Basys3 step-by-step — drowsiness CNN demo

Design = the integration RTL (`integration/rtl`: `drowsiness_top`, `input_control`, `drowsy_fsm`, `alert_control`)
+ the CNN core of this repo (`rtl/cnn_top.v`, `rom_weights.v`, ROM files in `ml/export/`).
Constraints: `integration/constraints/basys3.xdc`. Vivado 2025.2.1, part `xc7a35tcpg236-1`.

**Clock:** the board's 100 MHz clock goes through an MMCM in `drowsiness_top` to a **50 MHz** system clock, because
the team's `cnn_top` has a 16.6 ns path (conv2 MAC) that fails at 100 MHz. Debounce, 100 ms frames and the
display refresh are scaled, so the board behaves the same. When the CNN team pipelines that path, set
`CLK_MHZ = 100` in `drowsiness_top.v` to bypass the MMCM.

Paths below are relative to the repository root (`<repo>`). Use forward slashes in the Vivado Tcl console.

## 0. Before Vivado (2 min, optional but recommended)

After every `git pull`, run the simulations once (Git Bash, from the repository root):

```bash
GEN=1 bash integration/sim/run.sh
```

All lines must say `PASS` (`tb_top_real` takes ~2–3 min: it runs the team's `cnn_top` on all 16 images).

## 1. Put the design into your project

1. Start Vivado 2025.2.1 → create an empty RTL project (part `xc7a35tcpg236-1` or board Basys3, no sources) or
   open your existing one.
2. Bottom of the window → **Tcl Console** tab → paste and press Enter:

   ```tcl
   source {<repo>/integration/scripts/add_sources.tcl}
   ```

   It prints `INFO: drowsiness design added ... 6 RTL files, 8 .mem files`. (Run it again after any update; it
   replaces the old file list. Do not use "Add Sources" by hand — the `.mem` files must be added too.)
3. Check the **Sources** window:
   - Design Sources: **`drowsiness_top`** in bold (= top) with `u_input`, `u_fsm`, `u_core : cnn_top`
     (→ `rom_inst : rom_weights`), `u_alert` underneath.
   - Memory Initialization Files (or "Other"): `conv1_w/b, conv2_w/b, fc_w/b, images, seq .mem`.
   - Constraints: `basys3.xdc`.
   If `drowsiness_top` is not bold: right-click it → **Set as Top**.

## 2. Synthesis

1. Flow Navigator (left) → **Run Synthesis** → OK (default "Launch runs on local host", jobs 4–8).
2. Wait for "Synthesis successfully completed" → choose **Open Synthesized Design** (optional) or Cancel.
3. Check the **Messages** tab: no red *Errors*. Warnings about unused `led`/`sw` bits are fine.
   A warning *"could not open $readmem data file"* means a `.mem` file is missing → redo step 1.2.

## 3. Implementation + timing

1. **Run Implementation** → OK → wait for "Implementation successfully completed" → **Open Implemented Design**.
2. **Reports → Timing → Report Timing Summary** (or the *Design Timing Summary* tab):
   **WNS must be ≥ 0** (setup) and **WHS ≥ 0** (hold). If WNS is negative, see Troubleshooting.
3. Optional for the report: **Reports → Report Utilization** (LUT / FF / BRAM numbers).

## 4. Bitstream

1. **Generate Bitstream** → OK. Output:
   `<project>.runs/impl_1/drowsiness_top.bit`.

## 5. Program the Basys3

1. Board: jumper **JP1 (mode) on JTAG**, power switch (SW16, near the USB) **OFF**.
2. Connect the micro-USB cable to the **PROG/UART** port and the PC, switch power **ON** (red LED LD20 on).
3. Vivado → Flow Navigator → **Open Hardware Manager** → **Open Target → Auto Connect**.
   You should see `xc7a35t_0`. (Not found? → Troubleshooting "board not detected".)
4. **Program Device** → `xc7a35t_0` → Bitstream file = the `drowsiness_top.bit` above (leave Debug probes
   empty) → **Program**. The green DONE LED lights up.

The design is lost at power-off. To keep it: Tools → Generate Memory Configuration File / add a flash
config; only needed for the final demo.

## 6. Board test (what you should see)

Controls: **btnU** = reset, **btnC** = run one inference, **SW[3:0]** = image slot (binary),
**SW10** = sequence *scan* (slots 0, 1, … 15 in order), **SW11** = sequence *step* (btnC = next frame), **SW12** = sequence *slow* (1 frame/s),
**SW13** = low-confidence hold, **SW14** = sequence mode, **SW15** = latency view.
7-segment: `----` no result yet · `OPEn` / `CLSd` · `tirE` (DROWSY) · `SLEP` (MICROSLEEP).
LEDs: LD0–3 = slot, LD4 = busy, LD5 = eye closed, LD6 = sequence mode, LD7–13 = PERCLOS bar,
LD14 = DROWSY, LD15 = MICROSLEEP (blinks).

| Step | Do | Expect |
|---|---|---|
| 1 | after programming, all switches down, press btnU | `----`, LEDs off |
| 2 | SW[3:0] = 0000, press btnC | `CLSd` (slot 0 is an **open** eye the model gets wrong), LD5 on |
| 3 | SW[3:0] = 0001, press btnC | `OPEn` (slot 1 is a **closed** eye the model gets wrong) |
| 4 | slots 2–15 (SW = 0010 … 1111), btnC each | even slot → `CLSd`, odd slot → `OPEn` (all correct) |
| 5 | SW15 up | `1516` = latency in µs (75,826 cycles at 50 MHz); SW15 down again |
| 6 | SW14 up (sequence mode, dot on the right digit) | frames every 100 ms from `seq.mem`: ~3.5 s `OPEn`/`CLSd` with the PERCLOS bar growing → `tirE` (LD14) → `SLEP` with LD15 blinking → back to `tirE`, then the 6.4 s script repeats |
| 6b | SW14 up **+ SW12 up** (slow, best for watching / filming) | same script at **1 frame per second**: ~35 s `OPEn`/`CLSd` (blinks at frames 6 and 13), PERCLOS bar grows → `tirE` at ~36 s → `SLEP` + LD15 blinking at ~47 s → `tirE` at ~60 s → repeats every 64 s |
| 6c | SW14 up **+ SW11 up** (step) | nothing moves until you press **btnC**: one frame per press, LD0–3 show the slot of that frame → `tirE` after press 36, `SLEP` after press 47. Best for explaining frame by frame |
| 6d | SW14 up **+ SW10 up** (scan; add SW12 for 1 s or SW11 for btnC steps) | slots in order 0, 1, 2 … 15, 0 … (LD0–3 count up). Display always shows the eye result, so each frame must equal the manual result of that slot: 0 `CLSd`, 1 `OPEn`, then even `CLSd` / odd `OPEn`. DROWSY/MICROSLEEP only on LD14/LD15 |
| 7 | SW14 down | back to `----`, manual mode |

Normal sequence mode (SW10 down) follows the script in `integration/mem/seq.mem` (only the correctly classified
slots 2–15, in a story order: awake → drowsy → 10 closed in a row → awake), not 0, 1, 2 …
SW10 / SW11 / SW12 can be flipped while sequence mode runs; the drowsiness counters keep going (only SW14 resets them).
The drowsiness rules count *frames* (32-frame window, 8 closed in a row → SLEP), so in slow mode the same
events just take 10× longer in real time.

Slot labels / golden logits: `ml/export/expected.txt` (label 1 = open; display shows the
*prediction*). Take a photo/video of steps 2–6 for the report.

## Troubleshooting

- **WNS < 0 (timing fails)**: with the 50 MHz MMCM clock it should pass. If it does not (e.g. the CNN team
  changed `cnn_top`), open the worst path (Timing → double-click the top path) and send it to the CNN team;
  their known long path is `a1_idx` math → 484-entry `a1_mem` read → multiply → `acc2`. A lower clock is a
  one-line change: `CLK_MHZ` in `drowsiness_top.v` (VCO 1000 MHz / CLK_MHZ must be an integer ≥ 2, e.g. 40, 25).
- **Board not detected**: other USB cable/port (some cables are charge-only), power switch on, JP1 on JTAG.
  Drivers: run `E:\AMD-Tools\2025.2.1\Vivado\data\xicom\cable_drivers\nt64\digilent\install_digilent.exe`
  (as administrator), re-plug.
- **Display stays dark**: wrong bitstream (check the file name), or clock pin — `clk` must be on W5 (it is in
  `basys3.xdc`).
- **After the CNN team pushes changes**: `git pull` → step 0 → in Vivado re-run step 1.2,
  then **Reset Runs** (right-click synth_1 → Reset Runs) and run 2–5 again.
- **Script-only build** (no GUI, same result, bitstream copied to `integration/drowsiness_top.bit`):
  ```bash
  cd integration
  vivado -mode batch -source scripts/create_project.tcl && vivado -mode batch -source scripts/build.tcl
  ```
