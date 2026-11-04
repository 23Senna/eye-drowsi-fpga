`timescale 1ns / 1ps
//==============================================================================
// conv1_layer (filter-parallel, pipelined, 100 MHz target)
//   1x24x24 -> conv3x3 x4 filters -> +bias -> ReLU/requant(>>10) -> maxpool2x2
//   -> 4x11x11 uint7, written through the single a1 write port
//
// All 4 filters are computed at the same time (4 mac_pipe). Every filter sees the
// SAME input pixel in the same clock, so the image memory is still read with ONE
// address per clock (no banking / line buffer needed). Only the weight ROM word
// is 4 x int8 wide: w_data = {w_f3, w_f2, w_f1, w_f0} for the current tap.
//
// Start-up: the 4 biases are read once (b_addr 0..3) into local registers, then
// the tap generator is released.
//
// Pipeline (cycle numbers relative to the tap in the counters):
//   0 counters | 1 partial addr (A_*) | 2 final addr regs (img_addr, w_addr)
//   3 memory/ROM data (SYNC read, 1 cycle after the address) -> mac_pipe
//   4 prod | 5 acc (full sum + bias) | 6 ReLU+requant, maxpool -> hold regs
//   7.. the 4 pooled values are written one per clock (f0, f1, f2, f3)
//   (a new pooled position needs >= 36 taps, so the 4 writes never collide)
//
// Memories must be read synchronously (data one clock after the address).
// Output order / content of a1 is identical to the serial version:
//   a1[f*121 + orow*11 + ocol]
//==============================================================================
module conv1_layer (
    input                  clk,
    input                  rst,
    input                  start,        // pulse, ignored while busy
    output reg             done,         // 1-cycle pulse, after the last write

    output reg [9:0]       img_addr,
    input  [7:0]           img_data,

    output reg [3:0]       w_addr,       // tap index 0..8
    input  [31:0]          w_data,       // {w_f3, w_f2, w_f1, w_f0}
    output reg [1:0]       b_addr,
    input  signed [31:0]   b_data,

    output                 a1_we,
    output [8:0]           a1_waddr,
    output [7:0]           a1_wdata
);
    localparam NF = 4;

    // ---------------- start-up: load the 4 biases, then release the tap generator
    reg         run, busy;
    reg         bl_run;
    reg  [2:0]  bl_cnt;
    reg         cv1, cv2;
    reg  [1:0]  ci1, ci2;
    reg  [32*NF-1:0] bias_bus;

    // tap generator (cycle 0)
    reg [3:0] orow, ocol;
    reg       pr, pc;
    reg [1:0] kr, kc;

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
            orow <= 0; ocol <= 0; pr <= 0; pc <= 0; kr <= 0; kc <= 0;
        end else begin
            cv1 <= bl_run;
            cv2 <= cv1;
            if (start && !busy) begin
                busy <= 1'b1; bl_run <= 1'b1; bl_cnt <= 3'd0;
                orow <= 0; ocol <= 0; pr <= 0; pc <= 0; kr <= 0; kc <= 0;
            end else begin
                if (done) busy <= 1'b0;
                if (bl_run) begin
                    bl_cnt <= bl_cnt + 1;
                    if (bl_cnt == 3'd3) bl_run <= 1'b0;
                end
                if (cv2 && ci2 == 2'd3) run <= 1'b1;   // all biases loaded
                if (run) begin
                    if (kc == 2) begin
                        kc <= 0;
                        if (kr == 2) begin
                            kr <= 0;
                            if (pc == 0) pc <= 1;
                            else begin
                                pc <= 0;
                                if (pr == 0) pr <= 1;
                                else begin
                                    pr <= 0;
                                    if (ocol == 10) begin
                                        ocol <= 0;
                                        if (orow == 10) begin
                                            orow <= 0; run <= 1'b0;
                                        end else orow <= orow + 1;
                                    end else ocol <= ocol + 1;
                                end
                            end
                        end else kr <= kr + 1;
                    end else kc <= kc + 1;
                end
            end
        end
    end

    // tag = {valid, first, last, pr, pc}
    wire [4:0] tag0 = {run, (kr == 0 && kc == 0), (kr == 2 && kc == 2), pr, pc};
    reg  [4:0] t1, t2, t3, t4, t5;
    always @(posedge clk or posedge rst) begin
        if (rst) begin t1 <= 0; t2 <= 0; t3 <= 0; t4 <= 0; t5 <= 0; end
        else     begin t1 <= tag0; t2 <= t1; t3 <= t2; t4 <= t3; t5 <= t4; end
    end

    // ---------------- address pipeline (cycles 1, 2)
    reg [4:0] A_r, A_c;
    reg [3:0] A_w;
    always @(posedge clk) begin
        A_r      <= (orow << 1) + pr + kr;
        A_c      <= (ocol << 1) + pc + kc;
        A_w      <= kr * 3 + kc;
        img_addr <= A_r * 24 + A_c;
        w_addr   <= A_w;
    end

    // ---------------- NF parallel MACs (data valid in cycle 3 with tag t3)
    wire [32*NF-1:0] acc_bus;
    genvar i;
    generate
        for (i = 0; i < NF; i = i + 1) begin : g_mac
            mac_pipe u_mac (
                .clk(clk), .a(img_data), .w(w_data[8*i +: 8]),
                .bias(bias_bus[32*i +: 32]),
                .first(t3[3]), .acc(acc_bus[32*i +: 32])
            );
        end
    endgenerate

    // ---------------- ReLU + requant (cycle 5 -> 6), maxpool (cycle 6)
    reg       v6;
    reg [1:0] pos6;
    always @(posedge clk or posedge rst) begin
        if (rst) begin v6 <= 1'b0; pos6 <= 2'b00; end
        else     begin v6 <= t5[4] & t5[2]; pos6 <= t5[1:0]; end
    end

    wire [8*NF-1:0] pooled_bus;
    generate
        for (i = 0; i < NF; i = i + 1) begin : g_act
            wire [7:0] act;
            relu_requant #(.IN_W(32), .SHIFT(10), .OUT_W(8), .SAT(127)) u_act (
                .acc(acc_bus[32*i +: 32]), .act_out(act)
            );
            reg [7:0] act_r, p0, p1, p2;
            always @(posedge clk) begin
                act_r <= act;
                if (v6) case (pos6)
                    2'b00: p0 <= act_r;
                    2'b01: p1 <= act_r;
                    2'b10: p2 <= act_r;
                    default: ;
                endcase
            end
            maxpool2x2 u_pool (.p0(p0), .p1(p1), .p2(p2), .p3(act_r),
                               .max_val(pooled_bus[8*i +: 8]));
        end
    endgenerate

    // ---------------- hold + serial write of the NF pooled values (single write port)
    wire cap = v6 && (pos6 == 2'b11);

    reg [8*NF-1:0] hold;
    reg            wr_busy;
    reg [1:0]      wr_f;
    reg [8:0]      wa;
    reg [6:0]      pos;           // pooled position 0..120

    always @(posedge clk) if (cap) hold <= pooled_bus;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            wr_busy <= 1'b0; wr_f <= 2'd0; wa <= 9'd0; pos <= 7'd0; done <= 1'b0;
        end else begin
            done <= 1'b0;
            if (cap) begin
                wr_busy <= 1'b1;
                wr_f    <= 2'd0;
                wa      <= {2'b00, pos};
            end else if (wr_busy) begin
                wr_f <= wr_f + 1;
                wa   <= wa + 9'd121;
                if (wr_f == NF-1) begin
                    wr_busy <= 1'b0;
                    if (pos == 7'd120) begin pos <= 7'd0; done <= 1'b1; end
                    else               pos <= pos + 1;
                end
            end
        end
    end

    assign a1_we    = wr_busy;
    assign a1_waddr = wa;
    assign a1_wdata = hold[8*wr_f +: 8];
endmodule