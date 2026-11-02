`timescale 1ns/1ps
`include "tb_paths.vh"
// tb_drowsy_fsm.v
//  part 1 (manual mode): mock CNN answers from vectors/drowsy_trace.mem (made by drowsy_ref.py via
//          scripts/gen_sim_data.py); after every frame count / runs / perclos / state must match.
//  part 2 (sequence mode): slot order must follow seq.mem (2 laps, wrap), one frame per STEP_TICKS.
//  part 4: seq_scan -> slots 0, 1, ..., 15, 0, 1 in order.
//  part 3: seq_slow -> one frame per SLOW_TICKS; seq_step -> no frames without start_pulse, one per pulse.
module tb_drowsy_fsm;
    localparam N = 500, STEP = 200, SLOW = 500, SEQ_LEN = 64;
    reg clk = 0, rst = 1, start_pulse = 0, seq_mode = 0, seq_slow = 0, seq_step = 0, seq_scan = 0, low_conf_en = 1;
    reg [3:0] slot_sw = 4'd9;
    reg cnn_done = 0, cnn_eye = 0;
    reg signed [31:0] logit0 = 0, logit1 = 0;
    wire cnn_start, busy, frame_done, have_result, eye_state;
    wire [3:0] img_slot; wire [1:0] drowsy_state;
    wire [5:0] closed_count, closed_run, open_run; wire [6:0] perclos; wire [19:0] latency; wire [15:0] latency_us;

    reg [47:0] trace [0:N-1];
    reg [3:0]  seq   [0:SEQ_LEN-1];
    integer errors = 0, i, delay, starts = 0, last_start = 0, n0;

    drowsy_fsm #(.STEP_TICKS(STEP), .SLOW_TICKS(SLOW), .SEQ_LEN(SEQ_LEN), .SEQ_FILE(`MEM("seq.mem"))) dut (
        .clk(clk), .rst(rst), .start_pulse(start_pulse), .slot_sw(slot_sw), .seq_mode(seq_mode), .seq_slow(seq_slow), .seq_step(seq_step), .seq_scan(seq_scan),
        .low_conf_en(low_conf_en), .cnn_start(cnn_start), .cnn_done(cnn_done), .cnn_eye(cnn_eye),
        .cnn_logit0(logit0), .cnn_logit1(logit1), .img_slot(img_slot), .busy(busy),
        .frame_done(frame_done), .have_result(have_result), .eye_state(eye_state),
        .drowsy_state(drowsy_state), .closed_count(closed_count), .closed_run(closed_run),
        .open_run(open_run), .perclos(perclos), .latency(latency), .latency_us(latency_us));

    always #5 clk = ~clk;

    // mock CNN: answer `delay` cycles after cnn_start with the current eye / logits
    // (counter, no waits inside the always block: xsim never finished the old repeat/@ version)
    integer cnt = 0;
    always @(posedge clk) begin
        cnn_done <= 1'b0;
        if (cnn_start) begin
            starts = starts + 1;
            cnt <= delay;
        end else if (cnt != 0) begin
            cnt <= cnt - 1;
            if (cnt == 1) cnn_done <= 1'b1;
        end
    end

    initial begin
        $readmemh(`VEC("drowsy_trace.mem"), trace);
        $readmemh(`MEM("seq.mem"), seq);
        repeat (4) @(negedge clk); rst = 0;
        // ---------------- part 1: manual mode vs drowsy_ref ----------------
        for (i = 0; i < N; i = i + 1) begin
            cnn_eye = trace[i][44];
            delay   = 3 + (i % 17);
            if (trace[i][40]) begin logit0 = 32'sd100;  logit1 = 32'sd20; end   // |diff| < margin
            else if (cnn_eye) begin logit0 = -32'sd5000; logit1 = 32'sd5000; end
            else              begin logit0 = 32'sd5000;  logit1 = -32'sd5000; end
            @(negedge clk) start_pulse = 1; @(negedge clk) start_pulse = 0;
            @(posedge frame_done); @(negedge clk);
            if ({2'b0, closed_count, 2'b0, closed_run, 2'b0, open_run, 1'b0, perclos, 6'b0, drowsy_state}
                    !== trace[i][39:0] || eye_state !== trace[i][44] || latency !== delay + 1
                    || img_slot !== slot_sw || !have_result) begin
                errors = errors + 1;
                if (errors < 6)
                    $display("FAIL step %0d: cnt %0d crun %0d orun %0d pc %0d st %0d lat %0d | exp %h",
                             i, closed_count, closed_run, open_run, perclos, drowsy_state, latency, trace[i]);
            end
        end
        $display("part 1: %0d steps checked vs drowsy_ref, %0d errors", N, errors);

        // ---------------- part 2: sequence mode ----------------
        delay = 20; cnn_eye = 0; logit0 = 32'sd5000; logit1 = -32'sd5000;
        seq_mode = 1;
        @(negedge clk); @(negedge clk);
        if (closed_count !== 0 || have_result !== 0 || drowsy_state !== 0) begin
            errors = errors + 1; $display("FAIL: mode change did not clear state");
        end
        for (i = 0; i < 2 * SEQ_LEN; i = i + 1) begin
            @(posedge cnn_start);
            if (img_slot !== seq[i % SEQ_LEN]) begin
                errors = errors + 1;
                if (errors < 10) $display("FAIL seq %0d: slot %0d exp %0d", i, img_slot, seq[i % SEQ_LEN]);
            end
            if (i > 0 && ($time / 10 - last_start) !== STEP) begin
                errors = errors + 1;
                if (errors < 10) $display("FAIL seq %0d: step spacing %0d", i, $time / 10 - last_start);
            end
            last_start = $time / 10;
        end
        // start_pulse ignored in sequence mode
        @(negedge clk) start_pulse = 1; @(negedge clk) start_pulse = 0;
        repeat (STEP / 2) @(negedge clk);
        if (starts != N + 2 * SEQ_LEN) begin
            errors = errors + 1; $display("FAIL: %0d starts, exp %0d", starts, N + 2 * SEQ_LEN);
        end

        // ---------------- part 3: slow and step sequence ----------------
        seq_slow = 1;
        @(posedge cnn_start); last_start = $time / 10;      // first interval spans the rate change
        for (i = 0; i < 3; i = i + 1) begin
            @(posedge cnn_start);
            if (($time / 10 - last_start) !== SLOW) begin
                errors = errors + 1; $display("FAIL slow: spacing %0d, exp %0d", $time / 10 - last_start, SLOW);
            end
            last_start = $time / 10;
        end
        @(posedge frame_done); seq_slow = 0; seq_step = 1; n0 = starts;
        repeat (3 * SLOW) @(negedge clk);
        if (starts != n0) begin errors = errors + 1; $display("FAIL step: frames without btnC"); end
        for (i = 0; i < 3; i = i + 1) begin
            @(negedge clk) start_pulse = 1; @(negedge clk) start_pulse = 0;
            @(posedge frame_done); repeat (2 * STEP) @(negedge clk);
        end
        if (starts != n0 + 3) begin errors = errors + 1; $display("FAIL step: %0d frames for 3 presses", starts - n0); end

        // ---------------- part 4: scan order ----------------
        seq_step = 0; seq_scan = 1;
        for (i = 0; i < 18; i = i + 1) begin
            @(posedge cnn_start);
            if (img_slot !== i % 16) begin
                errors = errors + 1; $display("FAIL scan %0d: slot %0d", i, img_slot);
            end
        end
        seq_scan = 0;

        if (errors == 0) $display("PASS tb_drowsy_fsm (%0d trace steps, %0d sequence frames)", N, 2 * SEQ_LEN);
        else             $display("FAIL tb_drowsy_fsm: %0d errors", errors);
        $finish;
    end
    initial begin #5_000_000; $display("FAIL tb_drowsy_fsm: timeout"); $finish; end
endmodule
