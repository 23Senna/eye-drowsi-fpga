`timescale 1ns / 1ps
//==============================================================================
// cnn_top_150 : cnn_top re-pipelined for 150 MHz (same ports, same parameters,
//   same results; drop-in replacement for cnn_top)
//
// Structure and DSP/LUT budget are the same as cnn_top (80 DSP48 by default).
// Changes for 150 MHz (only registers were added, nothing was moved to a longer path):
//   * all buffer reads (img / a1 / a2) have 2 register stages: the first one is the
//     RAM read register, the second one is a plain register that a block RAM absorbs
//     as its output register (DOREG) -> short RAM -> DSP path
//   * rom_img_addr is a plain incrementer (no base + counter adder)
//   * layers: conv1_layer_150 / conv2_layer_150 / fc_layer_150 / rom_weights_150
//     (3-stage MACs, 3-stage address generators, 2-stage maxpool)
//
// Stage overlap and thresholds are unchanged: every read of the image / a1 buffer
// happens the same number of clocks or later after the event that releases it, so
// LOAD_AHEAD = 224 and L2_AHEAD_WR = 66 stay valid (checked by simulation against
// cnn_top, back to back, with stale buffer contents).
// Latency start -> done is ~20 clocks longer than cnn_top, at 150 MHz instead of 100 MHz.
//==============================================================================
module cnn_top_150 #(
    parameter EXTERNAL_INPUT = 0,
    // ---- DSP / LUT budget. DSP total = 16*C1_DSP_LANES + 32*(1 + C2_DSP_B) + 2*FC_DSP_LANES
    //   80 DSP (default) : C1_DSP_LANES = 3, C2_DSP_B = 0, FC_DSP_LANES = 0
    //   72 DSP           : C1_DSP_LANES = 2, C2_DSP_B = 0, FC_DSP_LANES = 4
    //   66 DSP           : C1_DSP_LANES = 2, C2_DSP_B = 0, FC_DSP_LANES = 1
    //   50 DSP           : C1_DSP_LANES = 1, C2_DSP_B = 0, FC_DSP_LANES = 1
    // The MAC count (and the latency) is the same in all cases: 48 + 64 + 8 MAC;
    // what is not in a DSP48 is built from LUTs.
    parameter C1_DSP_LANES = 3,   // 0..3  (16 DSP per lane)
    parameter C2_DSP_B     = 0,   // 0..1  (+32 DSP for the odd-channel chain)
    parameter FC_DSP_LANES = 0    // 0..4  (2 DSP per lane)
) (
    input clk,
    input rst,
    input start,
    input [13:0] img_base_addr,
    input external_image,
    output wire [9:0] external_addr,
    input [7:0] external_data,
    output reg done,
    output reg prediction,      // 0: Closed, 1: Open
    output signed [31:0] logit0,
    output signed [31:0] logit1
);

    // ---------------- Buffers
    reg [7:0] img_mem0 [0:575];  // 24x24 uint8 input image (8 identical copies)
    reg [7:0] img_mem1 [0:575];
    reg [7:0] img_mem2 [0:575];
    reg [7:0] img_mem3 [0:575];
    reg [7:0] img_mem4 [0:575];
    reg [7:0] img_mem5 [0:575];
    reg [7:0] img_mem6 [0:575];
    reg [7:0] img_mem7 [0:575];
    // a1 = 4x11x11 pooled feature map 1, split by channel parity:
    //   even memory: [f/2*121 + pos] for f = 0, 2     odd memory: same for f = 1, 3
    reg [7:0] a1e0 [0:241];      // even, one copy per pooling position
    reg [7:0] a1e1 [0:241];
    reg [7:0] a1e2 [0:241];
    reg [7:0] a1e3 [0:241];
    reg [7:0] a1o0 [0:241];      // odd
    reg [7:0] a1o1 [0:241];
    reg [7:0] a1o2 [0:241];
    reg [7:0] a1o3 [0:241];
    reg [7:0] a2_mem0  [0:31];   // 8x4x4 pooled feature map 2, 4 banks: a2[4*j + b]
    reg [7:0] a2_mem1  [0:31];
    reg [7:0] a2_mem2  [0:31];
    reg [7:0] a2_mem3  [0:31];

    // ---------------- Overlap thresholds
    localparam LOAD_AHEAD  = 224;   // pixels requested before conv1 may start (min 215 passes)
    localparam L2_AHEAD_WR = 66;    // a1 write cycles done before conv2 may start (min 60 passes)

    // ---------------- Top FSM
    localparam ST_IDLE     = 4'd0,
               ST_LOAD     = 4'd1,   // loader running, wait for LOAD_AHEAD pixels
               ST_L1_GO    = 4'd3,
               ST_L1_WAIT  = 4'd4,   // conv1 running, wait for L2_AHEAD_WR a1 writes
               ST_L2_GO    = 4'd5,
               ST_L2_WAIT  = 4'd6,   // conv1 and conv2 running, wait for both done
               ST_FC_GO    = 4'd7,
               ST_FC_WAIT  = 4'd8,
               ST_DONE     = 4'd9;

    reg [3:0] state;
    reg [9:0] load_cnt;
    reg       external_q;
    reg       ld_run;           // background loader active
    reg       ld_valid;         // image data of address ld_idx is on the data bus
    reg [9:0] ld_idx;
    reg [8:0] a1_wcnt;          // a1 write cycles so far (0..242)
    reg       l1_fin, l2_fin;   // sticky done flags of conv1 / conv2

    // layer handshakes
    wire l1_start = (state == ST_L1_GO);
    wire l2_start = (state == ST_L2_GO);
    wire fc_start = (state == ST_FC_GO);
    wire l1_done, l2_done, fc_done;

    // ---------------- ROM
    wire [3:0]  c1_w_addr;  wire signed [7:0] c1_w0, c1_w1, c1_w2, c1_w3;
    wire signed [7:0] c1_wl1_0, c1_wl1_1, c1_wl1_2, c1_wl1_3;   // conv1 lane 1 (tap + 1)
    wire signed [7:0] c1_wl2_0, c1_wl2_1, c1_wl2_2, c1_wl2_3;   // conv1 lane 2 (tap + 2)
    wire [1:0]  c1_b_addr;  wire signed [31:0] c1_b_data;
    wire [5:0]  c2_w_addr;  wire signed [7:0] c2_w0, c2_w1, c2_w2, c2_w3,
                                              c2_w4, c2_w5, c2_w6, c2_w7;
    wire signed [7:0] c2_wb0, c2_wb1, c2_wb2, c2_wb3,
                      c2_wb4, c2_wb5, c2_wb6, c2_wb7;   // second channel of the pair
    wire [2:0]  c2_b_addr;  wire signed [31:0] c2_b_data;
    wire [6:0]  fc_w_addr;  wire signed [7:0] fc_w0, fc_w1, fc_w2, fc_w3,
                                              fc_w4, fc_w5, fc_w6, fc_w7;
    wire        fc_b_addr;  wire signed [31:0] fc_b_data;
    reg  [13:0] rom_img_addr;
    assign external_addr = rom_img_addr[9:0];
    wire [7:0]  rom_img_data;

    rom_weights_150 rom_inst (
        .clk(clk),
        .conv1_w_addr(c1_w_addr),
        .conv1_w0_data(c1_w0), .conv1_w1_data(c1_w1),
        .conv1_w2_data(c1_w2), .conv1_w3_data(c1_w3),
        .conv1_wL1_0_data(c1_wl1_0), .conv1_wL1_1_data(c1_wl1_1),
        .conv1_wL1_2_data(c1_wl1_2), .conv1_wL1_3_data(c1_wl1_3),
        .conv1_wL2_0_data(c1_wl2_0), .conv1_wL2_1_data(c1_wl2_1),
        .conv1_wL2_2_data(c1_wl2_2), .conv1_wL2_3_data(c1_wl2_3),
        .conv1_b_addr(c1_b_addr), .conv1_b_data(c1_b_data),
        .conv2_w_addr(c2_w_addr),
        .conv2_w0_data(c2_w0), .conv2_w1_data(c2_w1),
        .conv2_w2_data(c2_w2), .conv2_w3_data(c2_w3),
        .conv2_w4_data(c2_w4), .conv2_w5_data(c2_w5),
        .conv2_w6_data(c2_w6), .conv2_w7_data(c2_w7),
        .conv2_wB0_data(c2_wb0), .conv2_wB1_data(c2_wb1),
        .conv2_wB2_data(c2_wb2), .conv2_wB3_data(c2_wb3),
        .conv2_wB4_data(c2_wb4), .conv2_wB5_data(c2_wb5),
        .conv2_wB6_data(c2_wb6), .conv2_wB7_data(c2_wb7),
        .conv2_b_addr(c2_b_addr), .conv2_b_data(c2_b_data),
        .fc_w_addr(fc_w_addr),
        .fc_w0_data(fc_w0), .fc_w1_data(fc_w1),
        .fc_w2_data(fc_w2), .fc_w3_data(fc_w3),
        .fc_w4_data(fc_w4), .fc_w5_data(fc_w5),
        .fc_w6_data(fc_w6), .fc_w7_data(fc_w7),
        .fc_b_addr(fc_b_addr),    .fc_b_data(fc_b_data),
        .img_addr(rom_img_addr),  .img_data(rom_img_data)
    );

    // ---------------- Layer 1 (8 image read ports, 2 a1 values written per clock)
    wire [8*10-1:0] l1_img_addr;
    reg  [8*8-1:0]  l1_img_data;    // sync read: data 1 clock after the address
    wire            a1_we;
    wire [7:0]      a1_waddr;
    wire [7:0]      a1_wdata0;      // even memory
    wire [7:0]      a1_wdata1;      // odd memory

    conv1_layer_150 #(.DSP_LANES(C1_DSP_LANES)) u_conv1 (
        .clk(clk), .rst(rst), .start(l1_start), .done(l1_done),
        .img_addr(l1_img_addr), .img_data(l1_img_data),
        .w_addr(c1_w_addr),
        .w_data0(c1_w0), .w_data1(c1_w1), .w_data2(c1_w2), .w_data3(c1_w3),
        .w_dataL1_0(c1_wl1_0), .w_dataL1_1(c1_wl1_1),
        .w_dataL1_2(c1_wl1_2), .w_dataL1_3(c1_wl1_3),
        .w_dataL2_0(c1_wl2_0), .w_dataL2_1(c1_wl2_1),
        .w_dataL2_2(c1_wl2_2), .w_dataL2_3(c1_wl2_3),
        .b_addr(c1_b_addr), .b_data(c1_b_data),
        .a1_we(a1_we), .a1_waddr(a1_waddr),
        .a1_wdata0(a1_wdata0), .a1_wdata1(a1_wdata1)
    );

    // ---------------- Layer 2 (4 a1 addresses, E+O data per position)
    wire [4*8-1:0]  l2_a1_addr;
    reg  [8*8-1:0]  l2_a1_data;     // sync read, {O,E} per position
    wire            a2_we;
    wire [6:0]      a2_waddr;
    wire [7:0]      a2_wdata;

    conv2_layer_150 #(.DSP_A(1), .DSP_B(C2_DSP_B)) u_conv2 (
        .clk(clk), .rst(rst), .start(l2_start), .done(l2_done),
        .a1_addr(l2_a1_addr), .a1_data(l2_a1_data),
        .w_addr(c2_w_addr),
        .w_data0(c2_w0), .w_data1(c2_w1), .w_data2(c2_w2), .w_data3(c2_w3),
        .w_data4(c2_w4), .w_data5(c2_w5), .w_data6(c2_w6), .w_data7(c2_w7),
        .w_dataB0(c2_wb0), .w_dataB1(c2_wb1), .w_dataB2(c2_wb2), .w_dataB3(c2_wb3),
        .w_dataB4(c2_wb4), .w_dataB5(c2_wb5), .w_dataB6(c2_wb6), .w_dataB7(c2_wb7),
        .b_addr(c2_b_addr), .b_data(c2_b_data),
        .a2_we(a2_we), .a2_waddr(a2_waddr), .a2_wdata(a2_wdata)
    );

    // ---------------- FC (4 a2 values per clock)
    wire [6:0]  fc_a2_addr;         // 4*j
    reg  [31:0] fc_a2_data;         // sync read

    fc_layer_150 #(.DSP_LANES(FC_DSP_LANES)) u_fc (
        .clk(clk), .rst(rst), .start(fc_start), .done(fc_done),
        .a2_addr(fc_a2_addr), .a2_data(fc_a2_data),
        .w_addr(fc_w_addr),
        .w_data0(fc_w0), .w_data1(fc_w1), .w_data2(fc_w2), .w_data3(fc_w3),
        .w_data4(fc_w4), .w_data5(fc_w5), .w_data6(fc_w6), .w_data7(fc_w7),
        .b_addr(fc_b_addr), .b_data(fc_b_data),
        .logit0(logit0), .logit1(logit1)
    );

    // ---------------- Buffer reads (2 stages: RAM read register, then output register)
    reg [8*8-1:0]  l1_img_d1;
    reg [8*8-1:0]  l2_a1_d1;
    reg [31:0]     fc_a2_d1;
    always @(posedge clk) begin
        l1_img_d1[ 7: 0] <= img_mem0[l1_img_addr[ 9: 0]];
        l1_img_d1[15: 8] <= img_mem1[l1_img_addr[19:10]];
        l1_img_d1[23:16] <= img_mem2[l1_img_addr[29:20]];
        l1_img_d1[31:24] <= img_mem3[l1_img_addr[39:30]];
        l1_img_d1[39:32] <= img_mem4[l1_img_addr[49:40]];
        l1_img_d1[47:40] <= img_mem5[l1_img_addr[59:50]];
        l1_img_d1[55:48] <= img_mem6[l1_img_addr[69:60]];
        l1_img_d1[63:56] <= img_mem7[l1_img_addr[79:70]];

        // position p reads E and O at the same address
        l2_a1_d1[ 7: 0]  <= a1e0[l2_a1_addr[ 7: 0]];
        l2_a1_d1[15: 8]  <= a1o0[l2_a1_addr[ 7: 0]];
        l2_a1_d1[23:16]  <= a1e1[l2_a1_addr[15: 8]];
        l2_a1_d1[31:24]  <= a1o1[l2_a1_addr[15: 8]];
        l2_a1_d1[39:32]  <= a1e2[l2_a1_addr[23:16]];
        l2_a1_d1[47:40]  <= a1o2[l2_a1_addr[23:16]];
        l2_a1_d1[55:48]  <= a1e3[l2_a1_addr[31:24]];
        l2_a1_d1[63:56]  <= a1o3[l2_a1_addr[31:24]];

        fc_a2_d1[ 7: 0]  <= a2_mem0[fc_a2_addr[6:2]];
        fc_a2_d1[15: 8]  <= a2_mem1[fc_a2_addr[6:2]];
        fc_a2_d1[23:16]  <= a2_mem2[fc_a2_addr[6:2]];
        fc_a2_d1[31:24]  <= a2_mem3[fc_a2_addr[6:2]];

        l1_img_data      <= l1_img_d1;
        l2_a1_data       <= l2_a1_d1;
        fc_a2_data       <= fc_a2_d1;
    end

    // ---------------- Buffer writes (same data into every copy)
    wire [7:0] ld_data = external_q ? external_data : rom_img_data;
    always @(posedge clk) begin
        if (ld_valid) begin
            img_mem0[ld_idx] <= ld_data;
            img_mem1[ld_idx] <= ld_data;
            img_mem2[ld_idx] <= ld_data;
            img_mem3[ld_idx] <= ld_data;
            img_mem4[ld_idx] <= ld_data;
            img_mem5[ld_idx] <= ld_data;
            img_mem6[ld_idx] <= ld_data;
            img_mem7[ld_idx] <= ld_data;
        end
        if (a1_we) begin
            a1e0[a1_waddr] <= a1_wdata0;
            a1e1[a1_waddr] <= a1_wdata0;
            a1e2[a1_waddr] <= a1_wdata0;
            a1e3[a1_waddr] <= a1_wdata0;
            a1o0[a1_waddr] <= a1_wdata1;
            a1o1[a1_waddr] <= a1_wdata1;
            a1o2[a1_waddr] <= a1_wdata1;
            a1o3[a1_waddr] <= a1_wdata1;
        end
        if (a2_we) begin
            case (a2_waddr[1:0])
                2'd0: a2_mem0[a2_waddr[6:2]] <= a2_wdata;
                2'd1: a2_mem1[a2_waddr[6:2]] <= a2_wdata;
                2'd2: a2_mem2[a2_waddr[6:2]] <= a2_wdata;
                2'd3: a2_mem3[a2_waddr[6:2]] <= a2_wdata;
            endcase
        end
    end

    // ---------------- Sequencing FSM
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state      <= ST_IDLE;
            done       <= 1'b0;
            prediction <= 1'b0;
            load_cnt   <= 10'd0;
            external_q <= 1'b0;
            ld_run     <= 1'b0;
            ld_valid   <= 1'b0;
            a1_wcnt    <= 9'd0;
            l1_fin     <= 1'b0;
            l2_fin     <= 1'b0;
        end else begin
            // ---- background image loader: a new address every clock, data 1 clock later
            if (ld_run) begin
                ld_valid <= 1'b1;
                ld_idx   <= load_cnt;                 // address on the bus now
                if (load_cnt == 575) begin
                    ld_run <= 1'b0;                   // last data is written next clock
                end else begin
                    load_cnt     <= load_cnt + 1;
                    rom_img_addr <= rom_img_addr + 14'd1;   // was img_base_addr + load_cnt + 1
                end
            end else begin
                ld_valid <= 1'b0;
            end

            // ---- progress trackers
            if (a1_we)   a1_wcnt <= a1_wcnt + 1;
            if (l1_done) l1_fin  <= 1'b1;
            if (l2_done) l2_fin  <= 1'b1;

            case (state)
                ST_IDLE: begin
                    done <= 1'b0;
                    if (start) begin
                        external_q   <= EXTERNAL_INPUT ? external_image : 1'b0;
                        load_cnt     <= 10'd0;
                        rom_img_addr <= img_base_addr;
                        ld_run       <= 1'b1;
                        ld_valid     <= 1'b0;
                        a1_wcnt      <= 9'd0;
                        l1_fin       <= 1'b0;
                        l2_fin       <= 1'b0;
                        state        <= ST_LOAD;
                    end
                end

                ST_LOAD:    if (load_cnt >= LOAD_AHEAD) state <= ST_L1_GO;

                ST_L1_GO:   state <= ST_L1_WAIT;
                ST_L1_WAIT: if (a1_wcnt >= L2_AHEAD_WR) state <= ST_L2_GO;

                ST_L2_GO:   state <= ST_L2_WAIT;
                ST_L2_WAIT: if ((l1_fin || l1_done) && (l2_fin || l2_done)) state <= ST_FC_GO;

                ST_FC_GO:   state <= ST_FC_WAIT;
                ST_FC_WAIT: if (fc_done) state <= ST_DONE;

                ST_DONE: begin
                    done       <= 1'b1;
                    prediction <= (logit1 > logit0) ? 1'b1 : 1'b0;
                    if (!start) state <= ST_IDLE;
                end

                default: state <= ST_IDLE;
            endcase
        end
    end

endmodule