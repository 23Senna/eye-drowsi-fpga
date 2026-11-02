`timescale 1ns/1ps
`include "tb_paths.vh"
`include "model_params.vh"
// tb_top_real.v - drowsiness_top with the CNN team's cnn_top (eye-drowsi-fpga/rtl), board pins only.
//  1. manual mode: every slot via btnC; eye_state / logits vs the Python golden, LEDs, 7-segment text
//  2. latency view (SW[15]): display = latency in microseconds (BCD)
//  3. sequence mode (SW[14]): one lap of seq.mem; eye + drowsy state vs drowsy_ref, display text
//  4. scan order (SW[14] + SW[10]): slots 0..15 in order, each frame = manual result, text OPEn/CLSd
// cnn_top/rom_weights read conv1_w.mem ... images.mem by bare name: run.sh runs this from sim/, where
// gen_sim_data.py copies them.
module tb_top_real;
    localparam RB = 6, STEP = 80000, NSEQ = 64;
    reg clk = 0, btnC = 0, btnU = 0;
    reg [15:0] sw = 16'h0000;
    wire [15:0] led; wire [6:0] seg; wire dp; wire [3:0] an;

    reg [47:0] gl      [0:15];
    reg [7:0]  seq_exp [0:127];
    reg [27:0] shown, exp_text;
    integer errors = 0, s, i, n_m = 0, g0, g1, lat, us;
    reg [1:0] st; reg pred;

    localparam [27:0] T_OPEN = {7'h3F, 7'h73, 7'h79, 7'h54}, T_CLSD = {7'h39, 7'h38, 7'h6D, 7'h5E},
                      T_TIRE = {7'h78, 7'h04, 7'h50, 7'h79}, T_SLEP = {7'h6D, 7'h38, 7'h79, 7'h73};

    drowsiness_top #(.CLK_MHZ(100), .DEB_CYCLES(4), .STEP_TICKS(STEP), .REFRESH_BITS(RB), .BLINK_BITS(8),
        .SEQ_FILE(`MEM("seq.mem")))
    dut (.clk(clk), .sw(sw), .btnC(btnC), .btnU(btnU), .led(led), .seg(seg), .dp(dp), .an(an));

    always #5 clk = ~clk;

    function integer sx24(input [23:0] b); sx24 = b[23] ? b - 24'hFFFFFF - 1 : b; endfunction
    function [6:0] hex7(input [3:0] h);
        case (h)
            4'd0: hex7 = 7'h3F; 4'd1: hex7 = 7'h06; 4'd2: hex7 = 7'h5B; 4'd3: hex7 = 7'h4F; 4'd4: hex7 = 7'h66;
            4'd5: hex7 = 7'h6D; 4'd6: hex7 = 7'h7D; 4'd7: hex7 = 7'h07; 4'd8: hex7 = 7'h7F; default: hex7 = 7'h6F;
        endcase
    endfunction

    task grab;   // one full refresh frame -> shown (active-high glyphs, digit 3 left)
        repeat (2 << RB) begin
            @(negedge clk);
            case (an)
                4'b1110: shown[6:0]   = ~seg;   4'b1101: shown[13:7]  = ~seg;
                4'b1011: shown[20:14] = ~seg;   4'b0111: shown[27:21] = ~seg;
            endcase
        end
    endtask

    task fail(input [8*24-1:0] what, input integer idx);
        begin errors = errors + 1; if (errors < 10) $display("FAIL %0s @%0d (t=%0t)", what, idx, $time); end
    endtask

    initial begin
        $readmemh(`MEM("stub_logits.mem"), gl);
        $readmemh(`VEC("seq_expected.mem"), seq_exp);
        btnU = 1; repeat (10) @(negedge clk); btnU = 0; repeat (30) @(negedge clk);

        // ---- 1. manual mode ----
        for (s = 0; s < `CNN_N_IMG; s = s + 1) begin
            sw[3:0] = s; repeat (20) @(negedge clk);
            btnC = 1; repeat (20) @(negedge clk); btnC = 0;
            @(posedge dut.frame_done); repeat (4) @(negedge clk);
            g0 = sx24(gl[s][47:24]); g1 = sx24(gl[s][23:0]); pred = (g0 >= g1);
            if (dut.eye_state !== pred)                       fail("manual eye", s);
            if (dut.logit0 !== g0 || dut.logit1 !== g1) begin
                fail("manual logits", s);
                if (errors < 10) $display("   got %0d %0d golden %0d %0d", dut.logit0, dut.logit1, g0, g1);
            end
            if (led[5] !== pred || led[3:0] !== s)            fail("manual LEDs", s);
            grab; if (shown !== (pred ? T_CLSD : T_OPEN))     fail("manual text", s);
        end
        lat = dut.latency; us = lat / 100;
        $display("manual: %0d slots checked, %0d errors; cnn_top latency %0d cycles (%0d us)", `CNN_N_IMG, errors, lat, us);

        // ---- 2. latency view: microseconds, 4 decimal digits ----
        sw[15] = 1; repeat (20) @(negedge clk);
        grab; if (shown !== {hex7(us / 1000), hex7(us / 100 % 10), hex7(us / 10 % 10), hex7(us % 10)}) fail("latency view", us);
        sw[15] = 0; repeat (20) @(negedge clk);

        // ---- 3. sequence mode ----
        sw[14] = 1; repeat (20) @(negedge clk);
        for (i = 0; i < NSEQ; i = i + 1) begin
            @(posedge dut.frame_done); repeat (4) @(negedge clk);
            st = dut.drowsy_state;
            if ({3'b0, dut.eye_state, 2'b0, st} !== seq_exp[i]) fail("seq eye/state", i);
            exp_text = (st == 2) ? T_SLEP : (st == 1) ? T_TIRE : dut.eye_state ? T_CLSD : T_OPEN;
            grab; if (shown !== exp_text) fail("seq text", i);
            if (st == 2) n_m = n_m + 1;
        end
        $display("sequence: %0d frames checked (%0d in MICROSLEEP), %0d errors total", NSEQ, n_m, errors);

        // ---- 4. scan order: same results as manual mode, in slot order ----
        sw[10] = 1;
        for (i = 0; i < 16; i = i + 1) begin
            @(posedge dut.frame_done); repeat (4) @(negedge clk);
            g0 = sx24(gl[i][47:24]); g1 = sx24(gl[i][23:0]); pred = (g0 >= g1);
            if (dut.img_slot !== i || dut.eye_state !== pred) fail("scan slot/eye", i);
            grab; if (shown !== (pred ? T_CLSD : T_OPEN))   fail("scan text", i);
        end
        $display("scan: 16 frames checked, %0d errors total", errors);

        if (errors == 0) $display("PASS tb_top_real (cnn_top: %0d slots bit-exact, latency %0d cycles)", `CNN_N_IMG, lat);
        else             $display("FAIL tb_top_real: %0d errors", errors);
        $finish;
    end

    initial begin #300_000_000; $display("FAIL tb_top_real: timeout"); $finish; end
endmodule
