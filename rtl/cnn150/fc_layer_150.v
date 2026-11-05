`timescale 1ns / 1ps
//==============================================================================
// fc_layer_150 : fc_layer re-pipelined for 150 MHz (same function, same ports)
//   128 -> 2, raw int32 logits:  logit[c] = bias[c] + sum_i a2[i] * w[c*128 + i]
//
// 2 classes x 4 lanes = 8 MACs, 4 taps per clock, 32 clocks (as before).
//   a2_addr / w_addr = 4*j. The weight address is now the counter itself (cycle 0)
//   because rom_weights_150 needs 3 clocks to return the weights; a2_data must be
//   valid at cycle 3 (top has 2 read stages after the registered a2_addr).
//
//   0 counters, w_addr | 1 a2_addr reg, ROM addr regs | 2 memory/ROM read
//   3 operands valid -> mac | 4 operand regs | 5 prod | 6 acc | 7 lane sums
//   8 logit registers (done)
//==============================================================================
module fc_layer_150 #(
    parameter DSP_LANES = 0      // lanes b < DSP_LANES use DSP48 (2 DSP per lane), rest LUT
)(
    input                      clk,
    input                      rst,
    input                      start,       // pulse, ignored while busy
    output reg                 done,        // 1-cycle pulse, after the logits are written

    output reg [6:0]           a2_addr,     // 4*j
    input  [31:0]              a2_data,     // 4 consecutive a2 values

    output [6:0]               w_addr,      // 4*j (shared by both classes), = counter
    input  signed [7:0]        w_data0,     // class 0, tap 4j+0
    input  signed [7:0]        w_data1,     // class 0, tap 4j+1
    input  signed [7:0]        w_data2,     // class 0, tap 4j+2
    input  signed [7:0]        w_data3,     // class 0, tap 4j+3
    input  signed [7:0]        w_data4,     // class 1, tap 4j+0
    input  signed [7:0]        w_data5,     // class 1, tap 4j+1
    input  signed [7:0]        w_data6,     // class 1, tap 4j+2
    input  signed [7:0]        w_data7,     // class 1, tap 4j+3
    output reg                 b_addr,
    input  signed [31:0]       b_data,

    output reg signed [31:0]   logit0,
    output reg signed [31:0]   logit1
);
    localparam NF = 2;   // classes
    localparam NL = 4;   // taps per clock

    // ---------------- start-up: load the 2 biases, then release the tap generator
    reg         run, busy;
    reg         bl_run;
    reg         bl_cnt;
    reg         cv1, cv2;
    reg         ci1, ci2;
    reg  [32*NF-1:0] bias_bus;

    // tap generator (cycle 0): cnt = 4*j
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
                    if (cnt == 7'd124) begin cnt <= 7'd0; run <= 1'b0; end
                    else cnt <= cnt + 7'd4;
                end
            end
        end
    end

    // tag = {valid, first, last}; t_k = tag delayed by k clocks = tp[3*(k-1) +: 3]
    wire [2:0] tag0 = {run, (cnt == 7'd0), (cnt == 7'd124)};
    reg  [3*7-1:0] tp;
    always @(posedge clk or posedge rst) begin
        if (rst) tp <= 0;
        else     tp <= {tp[3*6-1:0], tag0};
    end
    wire [2:0] t3 = tp[3*2 +: 3];    // operands valid at the MAC inputs
    wire [2:0] t7 = tp[3*6 +: 3];    // lane sums valid

    // ---------------- address regs (cycle 1); the ROM address is the counter itself
    assign w_addr = cnt;
    always @(posedge clk) a2_addr <= cnt;

    // ---------------- NF x NL parallel MACs (operands valid in cycle 3 with tag t3)
    wire [8*NF*NL-1:0]  w_bus = {w_data7, w_data6, w_data5, w_data4,
                                 w_data3, w_data2, w_data1, w_data0};   // index 4*c + b
    wire [32*NF*NL-1:0] acc_bus;
    genvar c, b;
    generate
        for (c = 0; c < NF; c = c + 1) begin : g_cls
            for (b = 0; b < NL; b = b + 1) begin : g_mac
                mac_sel_150 #(.USE_DSP(b < DSP_LANES)) u_mac (
                    .clk(clk), .a(a2_data[8*b +: 8]), .w(w_bus[8*(NL*c+b) +: 8]),
                    .bias((b == 0) ? bias_bus[32*c +: 32] : 32'sd0),   // lane 0 carries bias
                    .first(t3[1]), .acc(acc_bus[32*(NL*c+b) +: 32])
                );
            end
        end
    endgenerate

    // ---------------- lane sums (cycle 6 -> 7) and result (cycle 7 -> 8)
    reg signed [31:0] s01_0, s23_0, s01_1, s23_1;
    always @(posedge clk) begin
        s01_0 <= acc_bus[32*0 +: 32] + acc_bus[32*1 +: 32];
        s23_0 <= acc_bus[32*2 +: 32] + acc_bus[32*3 +: 32];
        s01_1 <= acc_bus[32*4 +: 32] + acc_bus[32*5 +: 32];
        s23_1 <= acc_bus[32*6 +: 32] + acc_bus[32*7 +: 32];
    end

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            logit0 <= 32'sd0;
            logit1 <= 32'sd0;
            done   <= 1'b0;
        end else begin
            done <= 1'b0;
            if (t7[2] && t7[0]) begin
                logit0 <= s01_0 + s23_0;
                logit1 <= s01_1 + s23_1;
                done   <= 1'b1;
            end
        end
    end
endmodule