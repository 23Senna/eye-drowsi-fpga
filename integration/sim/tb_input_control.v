`timescale 1ns/1ps
// tb_input_control.v - debounce, one-pulse, switch sync, reset sync.
module tb_input_control;
    localparam DEB = 8;
    reg clk = 0, btnC = 0, btnU = 0;
    reg [15:0] sw = 0;
    wire rst, start_pulse, seq_scan, seq_step, seq_slow, low_conf_en, seq_mode, lat_view;
    wire [3:0] slot;
    integer pulses = 0, errors = 0, i;

    input_control #(.DEB_CYCLES(DEB)) dut (
        .clk(clk), .btnC(btnC), .btnU(btnU), .sw(sw), .rst(rst), .start_pulse(start_pulse),
        .slot(slot), .seq_scan(seq_scan), .seq_step(seq_step), .seq_slow(seq_slow), .low_conf_en(low_conf_en), .seq_mode(seq_mode), .lat_view(lat_view));

    always #5 clk = ~clk;
    always @(posedge clk) if (start_pulse) pulses = pulses + 1;

    task check(input cond, input [8*40-1:0] msg);
        if (!cond) begin errors = errors + 1; $display("FAIL: %0s (t=%0t)", msg, $time); end
    endtask

    // bouncy press: 6 short glitches, then hold for `hold` cycles, then bouncy release
    task press(input integer hold);
        begin
            for (i = 0; i < 6; i = i + 1) begin
                btnC = 1; repeat (2) @(negedge clk); btnC = 0; repeat (2) @(negedge clk);
            end
            btnC = 1; repeat (hold) @(negedge clk);
            for (i = 0; i < 6; i = i + 1) begin
                btnC = 0; repeat (2) @(negedge clk); btnC = 1; repeat (2) @(negedge clk);
            end
            btnC = 0; repeat (3 * DEB) @(negedge clk);
        end
    endtask

    initial begin
        repeat (20) @(negedge clk);
        check(!rst, "power-on reset released");
        // reset sync: btnU high -> rst within 3 cycles
        btnU = 1; repeat (3) @(negedge clk); check(rst, "rst follows btnU");
        btnU = 0; repeat (3) @(negedge clk); check(!rst, "rst released");

        press(4 * DEB);  check(pulses == 1, "one pulse per bouncy press");
        press(4 * DEB);  check(pulses == 2, "second press");
        // glitch shorter than DEB -> no pulse
        btnC = 1; repeat (DEB - 3) @(negedge clk); btnC = 0; repeat (3 * DEB) @(negedge clk);
        check(pulses == 2, "short glitch ignored");
        // long hold -> still only one pulse
        btnC = 1; repeat (20 * DEB) @(negedge clk); btnC = 0; repeat (3 * DEB) @(negedge clk);
        check(pulses == 3, "long hold = one pulse");

        // switches
        sw = 16'b1110_0000_0000_1101; repeat (2) @(negedge clk);
        check(slot == 4'd0, "switch not yet accepted");
        repeat (DEB + 4) @(negedge clk);
        check(slot == 4'd13 && low_conf_en && seq_mode && lat_view, "switches accepted");
        sw = 16'h0003; repeat (DEB + 4) @(negedge clk);
        check(slot == 4'd3 && !low_conf_en && !seq_mode && !lat_view, "switches change");
        check(!seq_step && !seq_slow, "SW11/12 off");
        sw = 16'b0001_1000_0000_0000; repeat (DEB + 4) @(negedge clk);
        check(seq_step && seq_slow && !seq_scan && !low_conf_en && slot == 4'd0, "SW11 step, SW12 slow");
        sw = 16'b0000_0100_0000_0000; repeat (DEB + 4) @(negedge clk);
        check(seq_scan && !seq_step && !seq_slow, "SW10 scan");

        if (errors == 0) $display("PASS tb_input_control (%0d pulses)", pulses);
        else             $display("FAIL tb_input_control: %0d errors", errors);
        $finish;
    end
endmodule
