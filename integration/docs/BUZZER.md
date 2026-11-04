# Buzzer alarm (MH-FMD module on Pmod JA)

`rtl/buzzer_control.v` sounds the drowsiness alarm on an MH-FMD buzzer module (3 pins, 9012 PNP driver,
**I/O active low**, 3.3–5 V). One bitstream works with the passive and the active variant.

| Drowsy state (LED14 / LED15) | Sound |
|---|---|
| AWAKE | silent |
| DROWSY (`tirE`, LED14) | beep-beep at 2 Hz (256 ms on / 256 ms off) |
| MICROSLEEP (`SLEP`, LED15 blinks) | fast beeping at 8 Hz (64 ms on / 64 ms off) |

## Wiring (board powered off)

```
 Basys3 Pmod JA (top row, seen from the board edge)        MH-FMD module
   pin 1  J1  ---------------------------------------------  I/O
   pin 5  GND ---------------------------------------------  GND
   pin 6  3V3 ---------------------------------------------  VCC
```

JA top row = pins 1 2 3 4 GND 3V3 (pin 1 is marked on the silkscreen, pins 5/6 are GND/3V3 at the end of the row).
Use **3V3, not 5 V**: with a 5 V supply the 3.3 V "high" cannot switch the PNP fully off (it would buzz quietly).

## Switches

| Switch | Function |
|---|---|
| SW8 | up = **mute** (alarm silent; LEDs/display unchanged) |
| SW7 | buzzer type: down = **passive** module (FPGA makes a 2.5 kHz tone), up = **active** module (own ~2 kHz oscillator) |
| SW6 | up = **test sound** (continuous, also when AWAKE or muted) — use it to check the wiring |

Idle, reset and mute drive the I/O pin high (transistor off), so a passive buzzer never carries DC.

## Board test

Bitstream: `vivado -mode batch -source integration/scripts/build_uart.tcl` (output folder without spaces, e.g.
`-tclargs C:/Users/<you>/buzzer_hw`); program `drowsiness_top.bit`, press btnU, all switches down.

1. **Silent at start:** nothing sounds after programming / btnU (AWAKE). A short click while programming is normal.
2. **Wiring:** SW6 up → continuous sound. Set SW7 to match the module (passive: down, active: up). If a passive
   module only clicks or is silent, SW7 is probably up. SW6 down → silent.
3. **DROWSY / MICROSLEEP:** SW14 up (sequence mode from `seq.mem`). As the display goes `tirE` → beeps at 2 Hz,
   `SLEP` (LED15 blinking) → fast 8 Hz beeping, back to `OPEn` / `CLSd` → silent. SW12 up (1 frame/s) slows the
   sequence down so each phase lasts longer.
4. **Mute:** SW8 up during `SLEP` → silent, LED15 keeps blinking; SW8 down → beeping again.
5. **UART / camera (SW9 up):** uploaded frames drive the same drowsiness rules, so 8 closed frames in a row also
   start the 8 Hz beeping.

Troubleshooting: always sounding → I/O and VCC swapped, or VCC on 5 V; never sounding (even with SW6) → check
pin 1 vs pin 5/6, try the other SW7 position; too quiet (passive) → change `TONE_HZ` (2000–4000) in
`buzzer_control.v`, the loudest point is the module's resonance.

Simulation: `bash sim/run.sh tb_buzzer_control` (envelopes, tone period, active / mute / test).
