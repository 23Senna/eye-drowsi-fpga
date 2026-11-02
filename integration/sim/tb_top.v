`timescale 1ns/1ps
`include "tb_paths.vh"
`include "model_params.vh"
// tb_top.v - drowsiness_top built with USE_STUB (cnn_core_stub, golden logits), driven only through the board pins.
// (tb_top_real.v runs the same top with the CNN team's cnn_top.)
//  1. manual mode: all CNN_N_IMG slots via btnC; eye / logits vs the Python golden, pixel sum seen by the stub
//     (image-ROM slot addressing), latency, 7-segment text (OPEn / CLSd), LEDs
//  2. latency view (SW[15]): display = hex latency
//  3. sequence mode (SW[14]): 2 laps of seq.mem; eye + drowsy state vs drowsy_ref (seq_expected.mem),
//     display text on every frame (OPEn / CLSd / tirE / SLEP)
// The stub latency is shortened to LAT here to keep the run short (36124 on the board).
module tb_top;
    localparam RB = 6, LAT = 3000, STEP = 5000, NSEQ = 128;
    reg clk = 0, btnC = 0, btnU = 0;
    reg [15:0] sw = 16'h0000;
    wire [15:0] led; wire [6:0] seg; wire dp; wire [3:0] an;

    reg [47:0] gl     [0:15];
    reg [19:0] sums   [0:15];
    reg [7:0]  seq_exp [0:NSEQ-1];
    reg [27:0] shown, exp_text;
    integer errors = 0, s, i, n_m = 0, g0, g1;
    reg [1:0] st; reg pred;

    localparam [27:0] T_OPEN = {7'h3F, 7'h73, 7'h79, 7'h54}, T_CLSD = {7'h39, 7'h38, 7'h6D, 7'h5E},
                      T_TIRE = {7'h78, 7'h04, 7'h50, 7'h79}, T_SLEP = {7'h6D, 7'h38, 7'h79, 7'h73},
                      T_LAT  = {7'h3F, 7'h3F, 7'h4F, 7'h3F};   // 3000 cycles = 30 us -> "0030"

    drowsiness_top #(.CLK_MHZ(100), .DEB_CYCLES(4), .STEP_TICKS(STEP), .REFRESH_BITS(RB), .BLINK_BITS(8),
        .STUB_LATENCY(LAT), .IMG_FILE(`MEM("images.mem")), .W_FILE(`MEM("weights.mem")),
        .B_FILE(`MEM("biases.mem")), .SEQ_FILE(`MEM("seq.mem")), .LOGIT_FILE(`MEM("stub_logits.mem")))
    dut (.clk(clk), .sw(sw), .btnC(btnC), .btnU(btnU), .led(led), .seg(seg), .dp(dp), .an(an));

    always #5 clk = ~clk;

    function integer sx24(input [23:0] b); sx24 = b[23] ? b - 24'hFFFFFF - 1 : b; endfunction

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
        $readmemh(`VEC("slot_sum.mem"), sums);
        $readmemh(`VEC("seq_expected.mem"), seq_exp);
        btnU = 1; repeat (10) @(negedge clk); btnU = 0; repeat (30) @(negedge clk);
        grab; if (shown !== {4{7'h40}}) fail("---- after reset", 0);

        // ---- 1. manual mode ----
        for (s = 0; s < `CNN_N_IMG; s = s + 1) begin
            sw[3:0] = s; repeat (20) @(negedge clk);
            btnC = 1; repeat (20) @(negedge clk); btnC = 0;
            @(posedge dut.frame_done); repeat (4) @(negedge clk);
            g0 = sx24(gl[s][47:24]); g1 = sx24(gl[s][23:0]); pred = (g0 >= g1);
            if (dut.eye_state !== pred)                              fail("manual eye", s);
            if (dut.logit0 !== g0 || dut.logit1 !== g1)              fail("manual logits", s);
            if (dut.u_core.pix_sum !== sums[s])                      fail("manual pixel sum", s);
            if (dut.latency !== LAT)                                 fail("manual latency", s);
            if (led[5] !== pred || led[3:0] !== s)                   fail("manual LEDs", s);
            grab; if (shown !== (pred ? T_CLSD : T_OPEN))            fail("manual text", s);
        end
        $display("manual: %0d slots checked, %0d errors", `CNN_N_IMG, errors);

        // ---- 2. latency view ----
        sw[15] = 1; repeat (20) @(negedge clk);
        grab; if (shown !== T_LAT) fail("latency view", 0);
        sw[15] = 0; repeat (20) @(negedge clk);

        // ---- 3. sequence mode ----
        sw[14] = 1; repeat (20) @(negedge clk);
        grab; if (shown !== {4{7'h40}}) fail("---- after mode change", 0);
        for (i = 0; i < NSEQ; i = i + 1) begin
            @(posedge dut.frame_done); repeat (4) @(negedge clk);
            st = dut.drowsy_state;
            if ({3'b0, dut.eye_state, 2'b0, st} !== seq_exp[i]) begin
                fail("seq eye/state", i);
                if (errors < 10) $display("   got eye %0d st %0d exp %h", dut.eye_state, st, seq_exp[i]);
            end
            exp_text = (st == 2) ? T_SLEP : (st == 1) ? T_TIRE : dut.eye_state ? T_CLSD : T_OPEN;
            grab; if (shown !== exp_text) fail("seq text", i);
            if (st == 2) n_m = n_m + 1;
            if (led[14] !== (st == 1)) fail("seq LED14", i);
        end
        $display("sequence: %0d frames checked (%0d in MICROSLEEP), %0d errors total", NSEQ, n_m, errors);

        if (errors == 0) $display("PASS tb_top");
        else             $display("FAIL tb_top: %0d errors", errors);
        $finish;
    end

    initial begin #20_000_000; $display("FAIL tb_top: timeout"); $finish; end
endmodule
