`timescale 1ns / 1ps
//==============================================================================
// conv1_layer_150 : conv1_layer re-pipelined for 150 MHz (same function, same MAC
//   count, same ports, same results)
//   1x24x24 -> conv3x3 x4 filters -> +bias -> ReLU/requant(>>10) -> maxpool2x2
//   -> 4x11x11 uint7
//
// What changed w.r.t. conv1_layer (every change adds a register, no logic moved
// to a longer path):
//   * address: img_addr = row*24 + col is now 3 stages (row*24 | row24 + col+J)
//   * w_addr is issued at cycle 2 as before; rom_weights_150 returns the weights
//     3 clocks later (address reg, ROM read, output reg)
//   * the image data (img_data) must be valid at cycle 5 (top has 2 read stages)
//   * MACs are 3-stage (mac_sel_150): operand regs, product, accumulate
//   * maxpool is split in two stages (maxpool2x2_pipe)
//
// Pipeline (relative to the tap in the counters):
//   0 counters | 1 partial addr (row, col+J) | 2 row*24, w_addr | 3 img_addr, ROM addr regs
//   4 memory/ROM read | 5 operands valid -> mac | 6 operand regs | 7 prod | 8 acc
//   9 lane sum 1 | 10 lane sum 2 | 11 act_r (ReLU+requant) | 12 pool stage 1
//   13 hold -> the 2 write cycles (a new pooled position every 3 taps)
//==============================================================================
module conv1_layer_150 #(
    parameter DSP_LANES = 3      // lanes kc < DSP_LANES use DSP48 (16 DSP per lane), rest LUT
)(
    input                  clk,
    input                  rst,
    input                  start,        // pulse, ignored while busy
    output reg             done,         // 1-cycle pulse, after the last write

    // 8 read ports of the image memory, port q = pr*4 + j
    output [8*10-1:0]      img_addr,
    input  [8*8-1:0]       img_data,

    output reg [3:0]       w_addr,       // tap index of lane 0 (= kr*3), shared by all filters
    input  signed [7:0]    w_data0,      // int8 weight, filter 0, lane 0 (kc = 0)
    input  signed [7:0]    w_data1,      // filter 1
    input  signed [7:0]    w_data2,      // filter 2
    input  signed [7:0]    w_data3,      // filter 3
    input  signed [7:0]    w_dataL1_0,   // lane 1 (kc = 1), filter 0
    input  signed [7:0]    w_dataL1_1,
    input  signed [7:0]    w_dataL1_2,
    input  signed [7:0]    w_dataL1_3,
    input  signed [7:0]    w_dataL2_0,   // lane 2 (kc = 2), filter 0
    input  signed [7:0]    w_dataL2_1,
    input  signed [7:0]    w_dataL2_2,
    input  signed [7:0]    w_dataL2_3,
    output reg [1:0]       b_addr,
    input  signed [31:0]   b_data,

    output                 a1_we,
    output [7:0]           a1_waddr,
    output [7:0]           a1_wdata0,    // even memory (filters 0, 2)
    output [7:0]           a1_wdata1     // odd memory  (filters 1, 3)
);
    localparam NF = 4;   // filters
    localparam NP = 4;   // positions inside one pooling window
    localparam NL = 3;   // taps (kernel columns) per clock

    // ---------------- start-up: load the 4 biases, then release the tap generator
    reg         run, busy;
    reg         bl_run;
    reg  [2:0]  bl_cnt;
    reg         cv1, cv2;
    reg  [1:0]  ci1, ci2;
    reg  [32*NF-1:0] bias_bus;

    // tap generator (cycle 0)
    reg [3:0] orow, ocol;
    reg [1:0] kr;

    always @(posedge clk) b_addr <= bl_cnt[1:0];

    always @(posedge clk) begin
        ci1 <= bl_cnt[1:0];
        ci2 <= ci1;
        if (cv2) bias_bus[32*ci2 +: 32] <= b_data;
    end

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            run <= 1'b0; busy <= 1'b0; bl_run <= 1'b0; bl_cnt <= 3'd0;
            cv1 <= 1'b0; cv2 <= 1'b0;
            orow <= 0; ocol <= 0; kr <= 0;
        end else begin
            cv1 <= bl_run;
            cv2 <= cv1;
            if (start && !busy) begin
                busy <= 1'b1; bl_run <= 1'b1; bl_cnt <= 3'd0;
                orow <= 0; ocol <= 0; kr <= 0;
            end else begin
                if (done) busy <= 1'b0;
                if (bl_run) begin
                    bl_cnt <= bl_cnt + 1;
                    if (bl_cnt == 3'd3) bl_run <= 1'b0;
                end
                if (cv2 && ci2 == 2'd3) run <= 1'b1;   // all biases loaded
                if (run) begin
                    if (kr == 2) begin
                        kr <= 0;
                        if (ocol == 10) begin
                            ocol <= 0;
                            if (orow == 10) begin
                                orow <= 0; run <= 1'b0;
                            end else orow <= orow + 1;
                        end else ocol <= ocol + 1;
                    end else kr <= kr + 1;
                end
            end
        end
    end

    // tag = {valid, first, last}; t_k = tag delayed by k clocks = tp[3*(k-1) +: 3]
    wire [2:0] tag0 = {run, (kr == 0), (kr == 2)};
    reg  [3*8-1:0] tp;
    always @(posedge clk or posedge rst) begin
        if (rst) tp <= 0;
        else     tp <= {tp[3*7-1:0], tag0};
    end
    wire [2:0] t5 = tp[3*4 +: 3];    // operands valid at the MAC inputs
    wire [2:0] t8 = tp[3*7 +: 3];    // accumulator valid

    // ---------------- address pipeline (cycles 1, 2, 3)
    //   1: A_r0/A_r1 = image row of pr 0/1, A_w = tap, a_cj1[j] = col + j
    //   2: R24_x = row*24, w_addr, a_cj2[j]
    //   3: ia[q] = R24 + col + J
    reg [4:0] A_r0, A_r1;
    reg [3:0] A_w;
    reg [9:0] R24_0, R24_1;
    always @(posedge clk) begin
        A_r0   <= (orow << 1) + kr;          // image row of pr = 0
        A_r1   <= (orow << 1) + 1 + kr;      // image row of pr = 1
        A_w    <= kr * 3;
        R24_0  <= A_r0 * 24;
        R24_1  <= A_r1 * 24;
        w_addr <= A_w;
    end

    genvar p, i, q, k, j;
    generate
        for (j = 0; j < 4; j = j + 1) begin : g_col
            reg [4:0] a_cj1, a_cj2;          // first image column + j
            always @(posedge clk) begin
                a_cj1 <= (ocol << 1) + j;
                a_cj2 <= a_cj1;
            end
        end
        for (q = 0; q < 8; q = q + 1) begin : g_addr
            localparam PR = q >> 2;
            localparam J  = q & 3;
            reg [9:0] ia;
            always @(posedge clk) ia <= ((PR == 0) ? R24_0 : R24_1) + g_col[J].a_cj2;
            assign img_addr[10*q +: 10] = ia;
        end
    endgenerate

    // ---------------- NP x NF x NL parallel MACs (operands valid in cycle 5 with tag t5)
    wire [8*NF-1:0] w_bus0 = {w_data3,    w_data2,    w_data1,    w_data0};
    wire [8*NF-1:0] w_bus1 = {w_dataL1_3, w_dataL1_2, w_dataL1_1, w_dataL1_0};
    wire [8*NF-1:0] w_bus2 = {w_dataL2_3, w_dataL2_2, w_dataL2_1, w_dataL2_0};
    wire [32*NP*NF*NL-1:0] acc_bus;      // index ((p*NF + f)*NL + k)
    generate
        for (p = 0; p < NP; p = p + 1) begin : g_pos
            localparam PR = p >> 1;
            localparam PC = p & 1;
            for (i = 0; i < NF; i = i + 1) begin : g_mac
                mac_sel_150 #(.USE_DSP(DSP_LANES > 0)) u_mac0 (   // lane 0, carries bias
                    .clk(clk), .a(img_data[8*(PR*4 + PC + 0) +: 8]), .w(w_bus0[8*i +: 8]),
                    .bias(bias_bus[32*i +: 32]),
                    .first(t5[1]), .acc(acc_bus[32*((p*NF+i)*NL+0) +: 32])
                );
                mac_sel_150 #(.USE_DSP(DSP_LANES > 1)) u_mac1 (   // lane 1
                    .clk(clk), .a(img_data[8*(PR*4 + PC + 1) +: 8]), .w(w_bus1[8*i +: 8]),
                    .bias(32'sd0),
                    .first(t5[1]), .acc(acc_bus[32*((p*NF+i)*NL+1) +: 32])
                );
                mac_sel_150 #(.USE_DSP(DSP_LANES > 2)) u_mac2 (   // lane 2
                    .clk(clk), .a(img_data[8*(PR*4 + PC + 2) +: 8]), .w(w_bus2[8*i +: 8]),
                    .bias(32'sd0),
                    .first(t5[1]), .acc(acc_bus[32*((p*NF+i)*NL+2) +: 32])
                );
            end
        end
    endgenerate

    // ---------------- lane sum (8 -> 9 -> 10), ReLU + requant (10 -> 11), maxpool (11 -> 12 -> hold)
    reg v9, v10, v11, v12;
    always @(posedge clk or posedge rst) begin
        if (rst) begin v9 <= 1'b0; v10 <= 1'b0; v11 <= 1'b0; v12 <= 1'b0; end
        else     begin v9 <= t8[2] & t8[0]; v10 <= v9; v11 <= v10; v12 <= v11; end
    end

    wire [8*NF-1:0] pooled_bus;
    generate
        for (i = 0; i < NF; i = i + 1) begin : g_act
            wire [8*NP-1:0] act_bus;
            for (p = 0; p < NP; p = p + 1) begin : g_p
                reg signed [31:0] s01, l2d, sum_r;
                always @(posedge clk) begin
                    s01   <= acc_bus[32*((p*NF+i)*NL+0) +: 32] + acc_bus[32*((p*NF+i)*NL+1) +: 32];
                    l2d   <= acc_bus[32*((p*NF+i)*NL+2) +: 32];
                    sum_r <= s01 + l2d;
                end
                wire [7:0] act;
                relu_requant #(.IN_W(32), .SHIFT(10), .OUT_W(8), .SAT(127)) u_act (
                    .acc(sum_r), .act_out(act)
                );
                reg [7:0] act_r;
                always @(posedge clk) act_r <= act;
                assign act_bus[8*p +: 8] = act_r;
            end
            maxpool2x2_pipe u_pool (.clk(clk),
                               .p0(act_bus[7:0]),   .p1(act_bus[15:8]),
                               .p2(act_bus[23:16]), .p3(act_bus[31:24]),
                               .max_val(pooled_bus[8*i +: 8]));
        end
    endgenerate

    // ---------------- hold + 2-cycle write of the 4 pooled values (2 values per clock)
    wire cap = v12;

    reg [8*NF-1:0] hold;
    reg            wr_busy;
    reg            wr_f;           // 0: filters 0,1   1: filters 2,3
    reg [7:0]      wa;
    reg [6:0]      pos;            // pooled position 0..120

    always @(posedge clk) if (cap) hold <= pooled_bus;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            wr_busy <= 1'b0; wr_f <= 1'b0; wa <= 8'd0; pos <= 7'd0; done <= 1'b0;
        end else begin
            done <= 1'b0;
            if (cap) begin
                wr_busy <= 1'b1;
                wr_f    <= 1'b0;
                wa      <= {1'b0, pos};
            end else if (wr_busy) begin
                wr_f <= 1'b1;
                wa   <= wa + 8'd121;
                if (wr_f == 1'b1) begin
                    wr_busy <= 1'b0;
                    if (pos == 7'd120) begin pos <= 7'd0; done <= 1'b1; end
                    else               pos <= pos + 1;
                end
            end
        end
    end

    assign a1_we     = wr_busy;
    assign a1_waddr  = wa;
    assign a1_wdata0 = wr_f ? hold[23:16] : hold[7:0];     // filter 2 : filter 0
    assign a1_wdata1 = wr_f ? hold[31:24] : hold[15:8];    // filter 3 : filter 1
endmodule