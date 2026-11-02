`timescale 1ns / 1ps
//==============================================================================
// conv1_layer (pipelined, 100 MHz target)
//   1x24x24 -> conv3x3 x4 filters -> +bias -> ReLU/requant(>>10) -> maxpool2x2
//   -> 4x11x11 uint7, written through the a1 write port in index order 0..483
//
// One tap per clock. Pipeline (cycle numbers relative to the tap in the counters):
//   0 counters | 1 partial addr (A_*) | 2 final addr regs (img_addr,w_addr,b_addr)
//   3 memory/ROM data (SYNC read, 1 cycle after the address) -> mac_pipe
//   4 prod | 5 acc (full sum + bias) | 6 act_r (ReLU+requant) | 7 pooled_r + write
//
// Memories must be read synchronously: img_data / w_data / b_data show up one
// clock after img_addr / w_addr / b_addr.
//==============================================================================
module conv1_layer (
    input                  clk,
    input                  rst,
    input                  start,        // pulse, ignored while busy
    output reg             done,         // 1-cycle pulse, after the last write

    output reg [9:0]       img_addr,
    input  [7:0]           img_data,

    output reg [5:0]       w_addr,
    input  signed [7:0]    w_data,
    output reg [1:0]       b_addr,
    input  signed [31:0]   b_data,

    output                 a1_we,
    output [8:0]           a1_waddr,
    output [7:0]           a1_wdata
);
    // ---------------- tap generator (cycle 0)
    reg       run, busy;
    reg [1:0] f;
    reg [3:0] orow, ocol;
    reg       pr, pc;
    reg [1:0] kr, kc;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            run <= 1'b0; busy <= 1'b0;
            f <= 0; orow <= 0; ocol <= 0; pr <= 0; pc <= 0; kr <= 0; kc <= 0;
        end else begin
            if (start && !busy) begin
                busy <= 1'b1; run <= 1'b1;
                f <= 0; orow <= 0; ocol <= 0; pr <= 0; pc <= 0; kr <= 0; kc <= 0;
            end else begin
                if (done) busy <= 1'b0;
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
                                            orow <= 0;
                                            if (f == 3) begin f <= 0; run <= 1'b0; end
                                            else f <= f + 1;
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

    // tag = {valid, first, last, pos[1:0], f[1:0]}
    wire [6:0] tag0 = {run, (kr == 0 && kc == 0), (kr == 2 && kc == 2), pr, pc, f};
    reg  [6:0] t1, t2, t3, t4, t5;
    always @(posedge clk or posedge rst) begin
        if (rst) begin t1 <= 0; t2 <= 0; t3 <= 0; t4 <= 0; t5 <= 0; end
        else     begin t1 <= tag0; t2 <= t1; t3 <= t2; t4 <= t3; t5 <= t4; end
    end

    // ---------------- address pipeline (cycles 1, 2)
    reg [4:0] A_r, A_c;
    reg [5:0] A_w;
    always @(posedge clk) begin
        A_r      <= (orow << 1) + pr + kr;
        A_c      <= (ocol << 1) + pc + kc;
        A_w      <= f * 9 + kr * 3 + kc;
        img_addr <= A_r * 24 + A_c;
        w_addr   <= A_w;
        b_addr   <= t1[1:0];            // bias data arrives together with w_data
    end

    // ---------------- MAC (data valid in cycle 3 with tag t3)
    wire signed [31:0] acc;
    mac_pipe u_mac (
        .clk(clk), .a(img_data), .w(w_data), .bias(b_data),
        .first(t3[5]), .acc(acc)
    );

    // ---------------- ReLU + requant (cycle 5 -> 6)
    wire [7:0] act;
    relu_requant #(.IN_W(32), .SHIFT(10), .OUT_W(8), .SAT(127)) u_act (
        .acc(acc), .act_out(act)
    );

    reg [7:0] act_r;
    reg       v6;
    reg [1:0] pos6;
    always @(posedge clk or posedge rst) begin
        if (rst) begin v6 <= 1'b0; pos6 <= 2'b00; end
        else     begin v6 <= t5[6] & t5[4]; pos6 <= t5[3:2]; end
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
    reg [8:0] wcnt;
    always @(posedge clk) pooled_r <= pooled;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            we_r <= 1'b0; wcnt <= 9'd0; done <= 1'b0;
        end else begin
            we_r <= v6 && (pos6 == 2'b11);
            done <= 1'b0;
            if (we_r) begin
                if (wcnt == 9'd483) begin wcnt <= 9'd0; done <= 1'b1; end
                else                wcnt <= wcnt + 1;
            end
        end
    end

    assign a1_we    = we_r;
    assign a1_waddr = wcnt;
    assign a1_wdata = pooled_r;
endmodule