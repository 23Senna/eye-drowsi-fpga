`timescale 1ns / 1ps
//==============================================================================
// fc_layer (class-parallel, pipelined, 100 MHz target): 128 -> 2, raw int32 logits
//   logit[c] = bias[c] + sum_i a2[i] * w[c*128 + i]
//
// Both classes are computed at the same time (2 mac_pipe) from the same a2[i];
// w_data0 / w_data1 = int8 weight of class 0 / 1 at tap i. 128 taps instead of 256.
// The 2 biases are read once (b_addr 0..1) into local registers at start.
//
//   0 counters | 1 address regs | 2 memory/ROM data (sync read) -> mac_pipe
//   3 prod | 4 acc (full sum + bias) -> logit registers
//==============================================================================
module fc_layer (
    input                      clk,
    input                      rst,
    input                      start,       // pulse, ignored while busy
    output reg                 done,        // 1-cycle pulse, after the logits are written

    output reg [6:0]           a2_addr,
    input  [7:0]               a2_data,

    output reg [6:0]           w_addr,      // i = 0..127 (shared by both classes)
    input  signed [7:0]        w_data0,     // int8 weight, class 0
    input  signed [7:0]        w_data1,     // int8 weight, class 1
    output reg                 b_addr,
    input  signed [31:0]       b_data,

    output reg signed [31:0]   logit0,
    output reg signed [31:0]   logit1
);
    localparam NF = 2;

    // ---------------- start-up: load the 2 biases, then release the tap generator
    reg         run, busy;
    reg         bl_run;
    reg         bl_cnt;
    reg         cv1, cv2;
    reg         ci1, ci2;
    reg  [32*NF-1:0] bias_bus;

    // tap generator (cycle 0)
    reg [6:0] cnt;

    always @(posedge clk) b_addr <= bl_cnt;

    always @(posedge clk) begin
        ci1 <= bl_cnt;
        ci2 <= ci1;
        if (cv2) bias_bus[32*ci2 +: 32] <= b_data;
    end

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            run <= 1'b0; busy <= 1'b0; bl_run <= 1'b0; bl_cnt <= 1'b0;
            cv1 <= 1'b0; cv2 <= 1'b0; cnt <= 7'd0;
        end else begin
            cv1 <= bl_run;
            cv2 <= cv1;
            if (start && !busy) begin
                busy <= 1'b1; bl_run <= 1'b1; bl_cnt <= 1'b0; cnt <= 7'd0;
            end else begin
                if (done) busy <= 1'b0;
                if (bl_run) begin
                    bl_cnt <= bl_cnt + 1'b1;
                    if (bl_cnt == 1'b1) bl_run <= 1'b0;
                end
                if (cv2 && ci2 == 1'b1) run <= 1'b1;   // both biases loaded
                if (run) begin
                    if (cnt == 7'd127) begin cnt <= 7'd0; run <= 1'b0; end
                    else cnt <= cnt + 1;
                end
            end
        end
    end

    // tag = {valid, first, last}
    wire [2:0] tag0 = {run, (cnt == 7'd0), (cnt == 7'd127)};
    reg  [2:0] t1, t2, t3, t4;
    always @(posedge clk or posedge rst) begin
        if (rst) begin t1 <= 0; t2 <= 0; t3 <= 0; t4 <= 0; end
        else     begin t1 <= tag0; t2 <= t1; t3 <= t2; t4 <= t3; end
    end

    // ---------------- address regs (cycle 1)
    always @(posedge clk) begin
        a2_addr <= cnt;
        w_addr  <= cnt;
    end

    // ---------------- NF parallel MACs (data valid in cycle 2 with tag t2)
    wire [8*NF-1:0]  w_bus = {w_data1, w_data0};
    wire [32*NF-1:0] acc_bus;
    genvar i;
    generate
        for (i = 0; i < NF; i = i + 1) begin : g_mac
            mac_pipe u_mac (
                .clk(clk), .a(a2_data), .w(w_bus[8*i +: 8]),
                .bias(bias_bus[32*i +: 32]),
                .first(t2[1]), .acc(acc_bus[32*i +: 32])
            );
        end
    endgenerate

    // ---------------- result (cycle 4)
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            logit0 <= 32'sd0;
            logit1 <= 32'sd0;
            done   <= 1'b0;
        end else begin
            done <= 1'b0;
            if (t4[2] && t4[0]) begin
                logit0 <= acc_bus[31:0];
                logit1 <= acc_bus[63:32];
                done   <= 1'b1;
            end
        end
    end
endmodule