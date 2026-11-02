`timescale 1ns/1ps
`include "tb_paths.vh"
`include "model_params.vh"
// tb_cnn_control.v - cnn_control driving a behavioural integer datapath (one MAC, act = clip(acc>>>S,0,127),
// 2x2 max, FC) on the real export (weights.mem, biases.mem, images.mem). For all 16 slots the activation
// buffer must equal expected_a1 / expected_a2 and the logits / eye_state must equal the Python golden.
// S1, S2 and the image count come from rtl/model_params.vh (generated from the export).
module tb_cnn_control;
    localparam S1 = `CNN_S1, S2 = `CNN_S2, NIMG = `CNN_N_IMG;
    reg clk = 0, rst = 1, start = 0;
    wire busy, done, mac_en, mac_clr, mac_last, win_last, fc_class, argmax_en;
    wire [1:0] layer;
    wire [9:0] img_addr, act_rd_addr, act_wr_addr; wire [11:0] w_addr; wire [4:0] b_addr;

    reg [7:0]  img [0:16383];
    reg [7:0]  wm  [0:579];
    reg [31:0] bm  [0:13];
    reg [7:0]  ea1 [0:NIMG*484-1];
    reg [7:0]  ea2 [0:NIMG*128-1];
    reg [47:0] gl  [0:NIMG-1];
    reg [7:0]  abuf [0:1023];
    integer x, wv, bv, acc, acc_n, v, pmax, wc, logit0, logit1, g0, g1;
    integer slot = 0, errors = 0, n, i, lat, start_t;
    reg eye;

    cnn_control dut (
        .clk(clk), .rst(rst), .start(start), .busy(busy), .done(done), .img_addr(img_addr),
        .act_rd_addr(act_rd_addr), .w_addr(w_addr), .b_addr(b_addr), .layer(layer), .mac_en(mac_en),
        .mac_clr(mac_clr), .mac_last(mac_last), .win_last(win_last), .act_wr_addr(act_wr_addr),
        .fc_class(fc_class), .argmax_en(argmax_en));

    always #5 clk = ~clk;

    function integer sx8(input [7:0] b);   sx8  = b[7] ? b - 256 : b; endfunction
    function integer sx24(input [23:0] b); sx24 = b[23] ? b - 24'hFFFFFF - 1 : b; endfunction

    // registered memories (1-cycle read); the pixel source depends on the layer of the *issue* cycle,
    // so both are read every cycle and the datapath picks with the aligned `layer` strobe
    reg [7:0] pix, act; reg signed [7:0] wd; reg signed [31:0] bd;
    always @(posedge clk) begin
        pix <= img[{slot[3:0], img_addr}];
        act <= abuf[act_rd_addr];
        wd  <= wm[w_addr];
        bd  <= bm[b_addr];
    end

    always @(posedge clk) begin
        if (mac_en) begin
            x     = (layer == 2'd0) ? pix : act;
            acc_n = (mac_clr ? bd : acc) + x * wd;
            acc  <= acc_n;
            if (mac_last && layer != 2'd2) begin
                v    = acc_n >>> ((layer == 2'd0) ? S1 : S2);
                v    = (v < 0) ? 0 : (v > 127) ? 127 : v;
                pmax = (wc == 0 || v > pmax) ? v : pmax;
                wc   = wc + 1;
                if (win_last) begin abuf[act_wr_addr] <= pmax; wc = 0; end
            end
            if (mac_last && layer == 2'd2) begin if (fc_class) logit1 <= acc_n; else logit0 <= acc_n; end
        end
        if (argmax_en) eye <= (logit0 >= logit1);   // FC class 0 = closed; tie -> class 0
    end

    initial begin
        $readmemh(`MEM("images.mem"), img); $readmemh(`MEM("weights.mem"), wm);
        $readmemh(`MEM("biases.mem"), bm);   $readmemh(`MEM("stub_logits.mem"), gl);
        $readmemh(`VEC("expected_a1.mem"), ea1); $readmemh(`VEC("expected_a2.mem"), ea2);
        wc = 0;
        repeat (3) @(negedge clk); rst = 0;
        for (n = 0; n < NIMG; n = n + 1) begin
            slot = n;
            @(negedge clk) start = 1; start_t = $time; @(negedge clk) start = 0;
            @(negedge clk) start = 1; @(negedge clk) start = 0;          // ignored while busy
            @(posedge done); lat = ($time - start_t) / 10;
            @(negedge clk);
            g0 = sx24(gl[n][47:24]); g1 = sx24(gl[n][23:0]);
            for (i = 0; i < 484; i = i + 1) if (abuf[i] !== ea1[n*484 + i]) errors = errors + 1;
            for (i = 0; i < 128; i = i + 1) if (abuf[512 + i] !== ea2[n*128 + i]) errors = errors + 1;
            if (logit0 !== g0 || logit1 !== g1 || eye !== (g0 >= g1)) begin
                errors = errors + 1;
                $display("FAIL slot %0d: logits %0d %0d golden %0d %0d eye %0d", n, logit0, logit1, g0, g1, eye);
            end
            @(negedge clk);
            if (busy) begin errors = errors + 1; $display("FAIL: busy after done"); end
        end
        if (errors == 0) $display("PASS tb_cnn_control (%0d slots: a1, a2, logits = Python golden; latency %0d cycles)", NIMG, lat);
        else             $display("FAIL tb_cnn_control: %0d errors", errors);
        $finish;
    end
endmodule
