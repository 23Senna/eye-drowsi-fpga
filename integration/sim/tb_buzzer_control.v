`timescale 1ns / 1ps
// tb_buzzer_control - envelope (DROWSY 256/256 ticks, MICROSLEEP 64/64), passive tone period, active module = steady
// low, mute, test tone, reset/idle high. TICK = 4 cycles ("1 ms"), TONE_HALF = 3 cycles.
module tb_buzzer_control;
    localparam TICK = 4, HALF = 3;
    reg clk = 0, rst = 1;
    reg [1:0] state = 0;
    reg mute = 0, active = 0, test = 0;
    wire bz;
    integer errors = 0;

    buzzer_control #(.TICK_CYCLES(TICK), .TONE_HALF(HALF)) dut (
        .clk(clk), .rst(rst), .drowsy_state(state),
        .sw_mute(mute), .sw_active(active), .sw_test(test), .buzzer_n(bz));
    always #5 clk = ~clk;

    task fail(input [255:0] what);
        begin errors = errors + 1; $display("FAIL %0s at %0t", what, $time); end
    endtask

    // count cycles with bz low and high->low edges over n cycles
    integer lows, falls;
    task watch(input integer n);
        integer i; reg prev;
        begin
            lows = 0; falls = 0; prev = bz;
            for (i = 0; i < n; i = i + 1) begin
                @(posedge clk); #1;
                if (!bz) lows = lows + 1;
                if (prev && !bz) falls = falls + 1;
                prev = bz;
            end
        end
    endtask

    // wait until the ms counter starts a new 512-tick period (start of an "on" window)
    task sync_period;
        begin
            while (!(dut.ms == 9'd0 && dut.tick_cnt == 0)) @(posedge clk);
            repeat (2) @(posedge clk); #1;       // output register + one cycle of margin
        end
    endtask

    initial begin
        repeat (5) @(posedge clk); #1;
        if (bz !== 1'b1) fail("reset: buzzer_n must be high");
        rst = 0;

        // AWAKE: silent
        watch(600 * TICK);
        if (lows != 0) fail("AWAKE: not silent");

        // DROWSY, active module: 256 ticks low, 256 ticks high
        active = 1; state = 1; sync_period;
        watch(256 * TICK - 4); if (lows != 256 * TICK - 4) fail("DROWSY active: on window not steady low");
        repeat (8) @(posedge clk); #1;
        watch(256 * TICK - 16); if (lows != 0) fail("DROWSY active: off window not high");

        // DROWSY, passive module: square wave of period 2*HALF in the on window
        active = 0; sync_period; repeat (2) @(posedge clk);
        watch(240 * TICK);
        if (falls < (240 * TICK) / (2 * HALF) - 1 || falls > (240 * TICK) / (2 * HALF) + 1) fail("DROWSY passive: tone period");
        if (lows < (240 * TICK) / 2 - HALF || lows > (240 * TICK) / 2 + HALF) fail("DROWSY passive: tone duty");

        // MICROSLEEP, active module: 64 on / 64 off -> 4 bursts per 512 ticks
        active = 1; state = 2; sync_period;
        watch(512 * TICK - 8);
        if (falls != 3 || lows < 4 * 64 * TICK - 8 || lows > 4 * 64 * TICK) fail("MICROSLEEP active: 8 Hz envelope");

        // mute silences the alarm
        mute = 1; repeat (4) @(posedge clk);
        watch(600 * TICK); if (lows != 0) fail("mute: not silent");

        // test tone: sound even when AWAKE and muted
        state = 0; test = 1; repeat (4) @(posedge clk);
        watch(100); if (lows != 100) fail("test (active): not steady low");
        active = 0; repeat (4) @(posedge clk);
        watch(60); if (falls < 9) fail("test (passive): no tone");
        test = 0; repeat (4) @(posedge clk);
        watch(100); if (lows != 0) fail("test off: not silent");

        if (errors == 0) $display("PASS tb_buzzer_control (envelopes 2 Hz / 8 Hz, tone, active, mute, test)");
        else             $display("FAIL tb_buzzer_control: %0d errors", errors);
        $finish;
    end
endmodule
