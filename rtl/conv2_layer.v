`timescale 1ns / 1ps
//==============================================================================
// conv2_layer (pipelined, 100 MHz target)
//   4x11x11 -> conv3x3 x8 filters (4 in-ch) -> +bias -> ReLU/requant(>>6, = S2)
//   -> maxpool2x2 -> 8x4x4 uint7, written in index order 0..127
//
// Same pipeline as conv1_layer; memories/ROM are read synchronously
// (data one clock after the address).
//==============================================================================
module conv2_layer (
    input                  clk,
    input                  rst,
    input                  start,        // pulse, ignored while busy
    output reg             done,         // 1-cycle pulse, after the last write

    output reg [8:0]       a1_addr,
    input  [7:0]           a1_data,

    output reg [8:0]       w_addr,
    input  signed [7:0]    w_data,
    output reg [2:0]       b_addr,
    input  signed [31:0]   b_data,

    output                 a2_we,
    output [6:0]           a2_waddr,
    output [7:0]           a2_wdata
);
    // ---------------- tap generator (cycle 0)
    reg       run, busy;
    reg [2:0] f;
    reg [1:0] orow, ocol;
    reg       pr, pc;
    reg [1:0] ch, kr, kc;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            run <= 1'b0; busy <= 1'b0;
            f <= 0; orow <= 0; ocol <= 0; pr <= 0; pc <= 0; ch <= 0; kr <= 0; kc <= 0;
        end else begin
            if (start && !busy) begin
                busy <= 1'b1; run <= 1'b1;
                f <= 0; orow <= 0; ocol <= 0; pr <= 0; pc <= 0; ch <= 0; kr <= 0; kc <= 0;
            end else begin
                if (done) busy <= 1'b0;
                if (run) begin
                    if (kc == 2) begin
                        kc <= 0;
                        if (kr == 2) begin
                            kr <= 0;
                            if (ch == 3) begin
                                ch <= 0;
                                if (pc == 0) pc <= 1;
                                else begin
                                    pc <= 0;
                                    if (pr == 0) pr <= 1;
                                    else begin
                                        pr <= 0;
                                        if (ocol == 3) begin
                                            ocol <= 0;
                                            if (orow == 3) begin
                                                orow <= 0;
                                                if (f == 7) begin f <= 0; run <= 1'b0; end
                                                else f <= f + 1;
                                            end else orow <= orow + 1;
                                        end else ocol <= ocol + 1;
                                    end
                                end
                            end else ch <= ch + 1;
                        end else kr <= kr + 1;
                    end else kc <= kc + 1;
                end
            end
        end
    end

    // tag = {valid, first, last, pos[1:0], f[2:0]}
    wire [7:0] tag0 = {run, (kr == 0 && kc == 0 && ch == 0), (kr == 2 && kc == 2 && ch == 3),
                       pr, pc, f};
    reg  [7:0] t1, t2, t3, t4, t5;
    always @(posedge clk or posedge rst) begin
        if (rst) begin t1 <= 0; t2 <= 0; t3 <= 0; t4 <= 0; t5 <= 0; end
        else     begin t1 <= tag0; t2 <= t1; t3 <= t2; t4 <= t3; t5 <= t4; end
    end

    // ---------------- address pipeline (cycles 1, 2)
    reg [3:0] A_r, A_c;
    reg [8:0] A_ch, A_w;
    always @(posedge clk) begin
        A_r     <= (orow << 1) + pr + kr;
        A_c     <= (ocol << 1) + pc + kc;
        A_ch    <= ch * 121;
        A_w     <= f * 36 + ch * 9 + kr * 3 + kc;
        a1_addr <= A_ch + A_r * 11 + A_c;
        w_addr  <= A_w;
        b_addr  <= t1[2:0];
    end

    // ---------------- MAC (data valid in cycle 3 with tag t3)
    wire signed [31:0] acc;
    mac_pipe u_mac (
        .clk(clk), .a(a1_data), .w(w_data), .bias(b_data),
        .first(t3[6]), .acc(acc)
    );

    // ---------------- ReLU + requant (cycle 5 -> 6)
    wire [7:0] act;
    relu_requant #(.IN_W(32), .SHIFT(6), .OUT_W(8), .SAT(127)) u_act (   // SHIFT = S2 in ml/export/params.txt
        .acc(acc), .act_out(act)
    );

    reg [7:0] act_r;
    reg       v6;
    reg [1:0] pos6;
    always @(posedge clk or posedge rst) begin
        if (rst) begin v6 <= 1'b0; pos6 <= 2'b00; end
        else     begin v6 <= t5[7] & t5[5]; pos6 <= t5[4:3]; end
    end
    always @(posedge clk) act_r <= act;

    // ---------------- maxpool (cycle 6 -> 7)
    reg [7:0] p0, p1, p2;
    always @(posedge clk) begin
        if (v6) case (pos6)
            2'b00: p0 <= act_r;
            2'b01: p1 <= act_r;
            2'b10: p2 <= act_r;
            default: ;
        endcase
    end

    wire [7:0] pooled;
    maxpool2x2 u_pool (.p0(p0), .p1(p1), .p2(p2), .p3(act_r), .max_val(pooled));

    reg [7:0] pooled_r;
    reg       we_r;
    reg [6:0] wcnt;
    always @(posedge clk) pooled_r <= pooled;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            we_r <= 1'b0; wcnt <= 7'd0; done <= 1'b0;
        end else begin
            we_r <= v6 && (pos6 == 2'b11);
            done <= 1'b0;
            if (we_r) begin
                if (wcnt == 7'd127) begin wcnt <= 7'd0; done <= 1'b1; end
                else                wcnt <= wcnt + 1;
            end
        end
    end

    assign a2_we    = we_r;
    assign a2_waddr = wcnt;
    assign a2_wdata = pooled_r;
endmodule