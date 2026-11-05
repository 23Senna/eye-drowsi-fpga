`timescale 1ns / 1ps
//==============================================================================
// conv2_layer_150 : conv2_layer re-pipelined for 150 MHz (same function, same MAC
//   count, same ports, same results)
//   4x11x11 -> conv3x3 x8 filters (4 in-ch) -> +bias -> ReLU/requant(>>6, = S2)
//   -> maxpool2x2 -> 8x4x4 uint7, written through the single a2 write port
//
// What changed w.r.t. conv2_layer (every change adds a register):
//   * address: a1_addr = cp*121 + row*11 + col is now 3 stages
//     (row | cp*121 + row*11, col | + col)
//   * w_addr is issued at cycle 2; rom_weights_150 returns the weights 3 clocks later
//   * the a1 data (a1_data) must be valid at cycle 5 (top has 2 read stages)
//   * MACs are 3-stage (mac_sel_150)
//   * maxpool is split in two stages (maxpool2x2_pipe)
//
// Pipeline (relative to the tap in the counters):
//   0 counters | 1 partial addr (row, col, cp*121, tap) | 2 cp*121+row*11, w_addr
//   3 a1_addr, ROM addr regs | 4 memory/ROM read | 5 operands valid -> mac
//   6 operand regs | 7 prod | 8 acc | 9 sum (accA + accB) | 10 act_r (ReLU+requant)
//   11 pool stage 1 | 12 hold -> the 8 pooled values are written one per clock
//   (a new pooled position every 18 taps, the 8 writes never collide)
//
// a2 layout: a2[f*16 + orow*4 + ocol]
//==============================================================================
module conv2_layer_150 #(
    parameter DSP_A = 1,         // chain A (even channel) in DSP48: 32 DSP
    parameter DSP_B = 0          // chain B (odd channel) in DSP48: +32 DSP, else LUT
)(
    input                  clk,
    input                  rst,
    input                  start,        // pulse, ignored while busy
    output reg             done,         // 1-cycle pulse, after the last write

    // 4 read addresses (one per pooling position), 8 data bytes (E,O per position)
    output [4*8-1:0]       a1_addr,
    input  [8*8-1:0]       a1_data,

    output reg [5:0]       w_addr,       // channel-A tap index (shared by all filters)
    input  signed [7:0]    w_data0,      // int8 weight, filter 0, channel A
    input  signed [7:0]    w_data1,
    input  signed [7:0]    w_data2,
    input  signed [7:0]    w_data3,
    input  signed [7:0]    w_data4,
    input  signed [7:0]    w_data5,
    input  signed [7:0]    w_data6,
    input  signed [7:0]    w_data7,      // filter 7, channel A
    input  signed [7:0]    w_dataB0,     // int8 weight, filter 0, channel B
    input  signed [7:0]    w_dataB1,
    input  signed [7:0]    w_dataB2,
    input  signed [7:0]    w_dataB3,
    input  signed [7:0]    w_dataB4,
    input  signed [7:0]    w_dataB5,
    input  signed [7:0]    w_dataB6,
    input  signed [7:0]    w_dataB7,     // filter 7, channel B
    output reg [2:0]       b_addr,
    input  signed [31:0]   b_data,

    output                 a2_we,
    output [6:0]           a2_waddr,
    output [7:0]           a2_wdata
);
    localparam NF = 8;   // filters
    localparam NP = 4;   // positions inside one pooling window

    // ---------------- start-up: load the 8 biases, then release the tap generator
    reg         run, busy;
    reg         bl_run;
    reg  [3:0]  bl_cnt;
    reg         cv1, cv2;
    reg  [2:0]  ci1, ci2;
    reg  [32*NF-1:0] bias_bus;

    // tap generator (cycle 0)
    reg [1:0] orow, ocol;
    reg       cp;                // channel pair 0..1
    reg [1:0] kr, kc;

    always @(posedge clk) b_addr <= bl_cnt[2:0];

    always @(posedge clk) begin
        ci1 <= bl_cnt[2:0];
        ci2 <= ci1;
        if (cv2) bias_bus[32*ci2 +: 32] <= b_data;
    end

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            run <= 1'b0; busy <= 1'b0; bl_run <= 1'b0; bl_cnt <= 4'd0;
            cv1 <= 1'b0; cv2 <= 1'b0;
            orow <= 0; ocol <= 0; cp <= 0; kr <= 0; kc <= 0;
        end else begin
            cv1 <= bl_run;
            cv2 <= cv1;
            if (start && !busy) begin
                busy <= 1'b1; bl_run <= 1'b1; bl_cnt <= 4'd0;
                orow <= 0; ocol <= 0; cp <= 0; kr <= 0; kc <= 0;
            end else begin
                if (done) busy <= 1'b0;
                if (bl_run) begin
                    bl_cnt <= bl_cnt + 1;
                    if (bl_cnt == 4'd7) bl_run <= 1'b0;
                end
                if (cv2 && ci2 == 3'd7) run <= 1'b1;   // all biases loaded
                if (run) begin
                    if (kc == 2) begin
                        kc <= 0;
                        if (kr == 2) begin
                            kr <= 0;
                            if (cp == 1'b1) begin
                                cp <= 1'b0;
                                if (ocol == 3) begin
                                    ocol <= 0;
                                    if (orow == 3) begin
                                        orow <= 0; run <= 1'b0;
                                    end else orow <= orow + 1;
                                end else ocol <= ocol + 1;
                            end else cp <= 1'b1;
                        end else kr <= kr + 1;
                    end else kc <= kc + 1;
                end
            end
        end
    end

    // tag = {valid, first, last}; t_k = tag delayed by k clocks = tp[3*(k-1) +: 3]
    wire [2:0] tag0 = {run, (kr == 0 && kc == 0 && cp == 1'b0), (kr == 2 && kc == 2 && cp == 1'b1)};
    reg  [3*8-1:0] tp;
    always @(posedge clk or posedge rst) begin
        if (rst) tp <= 0;
        else     tp <= {tp[3*7-1:0], tag0};
    end
    wire [2:0] t5 = tp[3*4 +: 3];    // operands valid at the MAC inputs
    wire [2:0] t8 = tp[3*7 +: 3];    // accumulator valid

    // ---------------- address pipeline (cycles 1, 2, 3)
    //   1: A_ch = cp*121, A_w = tap, A_r / A_c per position (row, col in a1)
    //   2: R11 = A_ch + A_r*11, w_addr, col delayed
    //   3: aa = R11 + col
    reg [7:0] A_ch;                 // E/O index of the channel pair: cp * 121
    reg [5:0] A_w;
    always @(posedge clk) begin
        A_ch   <= cp ? 8'd121 : 8'd0;
        A_w    <= (cp ? 6'd18 : 6'd0) + kr * 3 + kc;
        w_addr <= A_w;
    end

    genvar p, i;
    generate
        for (p = 0; p < NP; p = p + 1) begin : g_addr
            localparam PR = p >> 1;
            localparam PC = p & 1;
            reg [3:0] A_r, A_c, A_c2;
            reg [7:0] R11, aa;
            always @(posedge clk) begin
                A_r  <= (orow << 1) + PR + kr;
                A_c  <= (ocol << 1) + PC + kc;
                R11  <= A_ch + A_r * 11;
                A_c2 <= A_c;
                aa   <= R11 + A_c2;
            end
            assign a1_addr[8*p +: 8] = aa;
        end
    endgenerate

    // ---------------- 2 x NP x NF parallel MACs (operands valid in cycle 5 with tag t5)
    wire [8*NF-1:0] w_busA = {w_data7,  w_data6,  w_data5,  w_data4,
                              w_data3,  w_data2,  w_data1,  w_data0};
    wire [8*NF-1:0] w_busB = {w_dataB7, w_dataB6, w_dataB5, w_dataB4,
                              w_dataB3, w_dataB2, w_dataB1, w_dataB0};
    wire [32*NP*NF*2-1:0] acc_bus;   // index ((p*NF + f)*2 + s)
    generate
        for (p = 0; p < NP; p = p + 1) begin : g_pos
            for (i = 0; i < NF; i = i + 1) begin : g_mac
                mac_sel_150 #(.USE_DSP(DSP_A)) u_macA (   // chain A, carries bias
                    .clk(clk), .a(a1_data[16*p +: 8]), .w(w_busA[8*i +: 8]),
                    .bias(bias_bus[32*i +: 32]),
                    .first(t5[1]), .acc(acc_bus[32*((p*NF+i)*2) +: 32])
                );
                mac_sel_150 #(.USE_DSP(DSP_B)) u_macB (   // chain B
                    .clk(clk), .a(a1_data[16*p+8 +: 8]), .w(w_busB[8*i +: 8]),
                    .bias(32'sd0),
                    .first(t5[1]), .acc(acc_bus[32*((p*NF+i)*2+1) +: 32])
                );
            end
        end
    endgenerate

    // ---------------- sum (cycle 9), ReLU + requant (9 -> 10), maxpool (10 -> 11 -> hold)
    reg v9, v10, v11;
    always @(posedge clk or posedge rst) begin
        if (rst) begin v9 <= 1'b0; v10 <= 1'b0; v11 <= 1'b0; end
        else     begin v9 <= t8[2] & t8[0]; v10 <= v9; v11 <= v10; end
    end

    wire [8*NF-1:0] pooled_bus;
    generate
        for (i = 0; i < NF; i = i + 1) begin : g_act
            wire [8*NP-1:0] act_bus;
            for (p = 0; p < NP; p = p + 1) begin : g_p
                reg signed [31:0] sum_r;
                always @(posedge clk)
                    sum_r <= acc_bus[32*((p*NF+i)*2) +: 32] + acc_bus[32*((p*NF+i)*2+1) +: 32];
                wire [7:0] act;
                relu_requant #(.IN_W(32), .SHIFT(6), .OUT_W(8), .SAT(127)) u_act (   // SHIFT = S2 in ml/export/params.txt
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

    // ---------------- hold + serial write of the NF pooled values (single write port)
    wire cap = v11;

    reg [8*NF-1:0] hold;
    reg            wr_busy;
    reg [2:0]      wr_f;
    reg [6:0]      wa;
    reg [3:0]      pos;           // pooled position 0..15

    always @(posedge clk) if (cap) hold <= pooled_bus;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            wr_busy <= 1'b0; wr_f <= 3'd0; wa <= 7'd0; pos <= 4'd0; done <= 1'b0;
        end else begin
            done <= 1'b0;
            if (cap) begin
                wr_busy <= 1'b1;
                wr_f    <= 3'd0;
                wa      <= {3'b000, pos};
            end else if (wr_busy) begin
                wr_f <= wr_f + 1;
                wa   <= wa + 7'd16;
                if (wr_f == NF-1) begin
                    wr_busy <= 1'b0;
                    if (pos == 4'd15) begin pos <= 4'd0; done <= 1'b1; end
                    else              pos <= pos + 1;
                end
            end
        end
    end

    assign a2_we    = wr_busy;
    assign a2_waddr = wa;
    assign a2_wdata = hold[8*wr_f +: 8];
endmodule