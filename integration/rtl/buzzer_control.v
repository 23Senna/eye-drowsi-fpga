// buzzer_control.v - drowsiness alarm for the MH-FMD buzzer module (9012 PNP driver, I/O active LOW) on Pmod JA1.
// AWAKE: silent · DROWSY: 2 Hz beeps (256 ms on / 256 ms off) · MICROSLEEP: 8 Hz beeps (64 ms on / 64 ms off).
// Passive module (sw_active = 0): "on" = square wave of TONE_HZ. Active module (sw_active = 1): "on" = I/O low
// (the module has its own ~2 kHz oscillator). sw_test = continuous sound (wiring check), even when muted.
// Idle, reset and mute drive I/O HIGH = transistor off (a passive buzzer held low would carry DC and stay silent).
// Module VCC must come from the Pmod 3.3 V pin, not 5 V, or a 3.3 V high cannot switch the PNP fully off.
module buzzer_control #(
    parameter CLK_MHZ     = 100,
    parameter TONE_HZ     = 2500,                               // passive tone; try 2000..4000 for the loudest
    parameter TICK_CYCLES = CLK_MHZ * 1000,                     // 1 ms (testbench overrides with a small value)
    parameter TONE_HALF   = CLK_MHZ * 1000000 / (2 * TONE_HZ)   // cycles per half tone period
) (
    input  wire       clk,
    input  wire       rst,
    input  wire [1:0] drowsy_state,   // 0 AWAKE, 1 DROWSY, 2 MICROSLEEP
    input  wire       sw_mute,        // SW8 up = silent
    input  wire       sw_active,      // SW7 up = active buzzer module (no tone generation)
    input  wire       sw_test,        // SW6 up = continuous sound
    output reg        buzzer_n        // to the module's I/O pin, active low
);
    // switches: 2-FF synchronizer (slow inputs, no debounce needed)
    reg [2:0] sw_m, sw_s;
    always @(posedge clk) begin
        sw_m <= {sw_test, sw_active, sw_mute};
        sw_s <= sw_m;
    end
    wire mute = sw_s[0], active = sw_s[1], test = sw_s[2];

    // 1 ms tick -> 9-bit ms counter (512 ms period): bit 8 = 2 Hz envelope, bit 6 = 8 Hz envelope
    reg [19:0] tick_cnt;                 // TICK_CYCLES, TONE_HALF <= 2^20
    reg [8:0]  ms;
    // tone generator
    reg [19:0] tone_cnt;
    reg        tone;

    wire alarm_on = (drowsy_state == 2'd1) ? ~ms[8] :
                    (drowsy_state == 2'd2) ? ~ms[6] : 1'b0;
    wire sound_on = test | (alarm_on & ~mute);

    always @(posedge clk) begin
        if (rst) begin
            tick_cnt <= 0; ms <= 0; tone_cnt <= 0; tone <= 1'b0;
            buzzer_n <= 1'b1;
        end else begin
            if (tick_cnt == TICK_CYCLES - 1) begin
                tick_cnt <= 0;
                ms       <= ms + 1'b1;
            end else
                tick_cnt <= tick_cnt + 1'b1;
            if (tone_cnt == TONE_HALF - 1) begin
                tone_cnt <= 0;
                tone     <= ~tone;
            end else
                tone_cnt <= tone_cnt + 1'b1;
            buzzer_n <= ~(sound_on & (active | tone));
        end
    end
endmodule
