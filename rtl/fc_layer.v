`timescale 1ns / 1ps
//==============================================================================
// fc_layer (pipelined, 100 MHz target): 128 -> 2, raw int32 logits
//   logit[c] = bias[c] + sum_i a2[i] * w[c*128 + i]
//
//   0 counters | 1 address regs | 2 memory/ROM data (sync read) -> mac_pipe
//   3 prod | 4 acc (full sum + bias) -> logit register
//==============================================================================
module fc_layer (
    input                      clk,
    input                      rst,
    input                      start,       // pulse, ignored while busy
    output reg                 done,        // 1-cycle pulse, after logit1 is written

    output reg [6:0]           a2_addr,
    input  [7:0]               a2_data,

    output reg [7:0]           w_addr,
    input  signed [7:0]        w_data,
    output reg                 b_addr,
    input  signed [31:0]       b_data,

    output reg signed [31:0]   logit0,
    output reg signed [31:0]   logit1
);
    // ---------------- tap generator (cycle 0)
    reg       run, busy, cls;
    reg [6:0] cnt;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            run <= 1'b0; busy <= 1'b0; cls <= 1'b0; cnt <= 7'd0;
        end else begin
            if (start && !busy) begin
                busy <= 1'b1; run <= 1'b1; cls <= 1'b0; cnt <= 7'd0;
            end else begin
                if (done) busy <= 1'b0;
                if (run) begin
                    if (cnt == 7'd127) begin
                        cnt <= 7'd0;
                        if (cls == 1'b0) cls <= 1'b1;
                        else begin cls <= 1'b0; run <= 1'b0; end
                    end else cnt <= cnt + 1;
                end
            end
        end
    end

    // tag = {valid, first, last, cls}
    wire [3:0] tag0 = {run, (cnt == 7'd0), (cnt == 7'd127), cls};
    reg  [3:0] t1, t2, t3, t4;
    always @(posedge clk or posedge rst) begin
        if (rst) begin t1 <= 0; t2 <= 0; t3 <= 0; t4 <= 0; end
        else     begin t1 <= tag0; t2 <= t1; t3 <= t2; t4 <= t3; end
    end

    // ---------------- address regs (cycle 1)
    always @(posedge clk) begin
        a2_addr <= cnt;
        w_addr  <= {cls, cnt};          // = cls*128 + cnt
        b_addr  <= cls;
    end

    // ---------------- MAC (data valid in cycle 2 with tag t2)
    wire signed [31:0] acc;
    mac_pipe u_mac (
        .clk(clk), .a(a2_data), .w(w_data), .bias(b_data),
        .first(t2[2]), .acc(acc)
    );

    // ---------------- result (cycle 4)
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            logit0 <= 32'sd0;
            logit1 <= 32'sd0;
            done   <= 1'b0;
        end else begin
            done <= 1'b0;
            if (t4[3] && t4[1]) begin
                if (t4[0] == 1'b0) logit0 <= acc;
                else begin
                    logit1 <= acc;
                    done   <= 1'b1;
                end
            end
        end
    end
endmodule