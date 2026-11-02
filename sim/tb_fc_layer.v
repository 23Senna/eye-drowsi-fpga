`timescale 1ns / 1ps

// Run from ml/export so the $readmemh file names resolve.
module tb_fc_layer #(
    parameter integer IMAGE = 0
);
    reg clk = 1'b0;
    reg rst = 1'b1;
    reg start = 1'b0;

    reg [7:0] a2_mem [0:2047];
    reg signed [7:0] weight_mem [0:255];
    reg signed [31:0] bias_mem [0:1];
    reg signed [31:0] expected_logit0 [0:15];
    reg signed [31:0] expected_logit1 [0:15];

    wire [6:0] a2_addr;
    reg [7:0] a2_data;
    wire [7:0] w_addr;
    reg signed [7:0] w_data;
    wire b_addr;
    reg signed [31:0] b_data;
    wire done;
    wire signed [31:0] logit0, logit1;

    integer i;
    integer errors;

    always #5 clk = ~clk;

    fc_layer dut (
        .clk(clk), .rst(rst), .start(start), .done(done),
        .a2_addr(a2_addr), .a2_data(a2_data),
        .w_addr(w_addr), .w_data(w_data),
        .b_addr(b_addr), .b_data(b_data),
        .logit0(logit0), .logit1(logit1)
    );

    always @(posedge clk) begin
        a2_data <= a2_mem[IMAGE * 128 + a2_addr];
        w_data  <= weight_mem[w_addr];
        b_data  <= bias_mem[b_addr];
    end

    initial begin
        $readmemh("expected_a2.mem", a2_mem);
        $readmemh("fc_w.mem", weight_mem);
        $readmemh("fc_b.mem", bias_mem);

        // expected.txt columns: slot label prediction logit0 logit1
        expected_logit0[0] = 1326;   expected_logit1[0] = -363;
        expected_logit0[1] = -632;   expected_logit1[1] = 3752;
        expected_logit0[2] = 7202;   expected_logit1[2] = -5075;
        expected_logit0[3] = -6948;  expected_logit1[3] = 11172;
        expected_logit0[4] = 18436;  expected_logit1[4] = -13446;
        expected_logit0[5] = -4666;  expected_logit1[5] = 9184;
        expected_logit0[6] = 9806;   expected_logit1[6] = -7346;
        expected_logit0[7] = -8355;  expected_logit1[7] = 13050;
        expected_logit0[8] = 18753;  expected_logit1[8] = -13755;
        expected_logit0[9] = -8922;  expected_logit1[9] = 13489;
        expected_logit0[10] = 5870;  expected_logit1[10] = -3755;
        expected_logit0[11] = -7031; expected_logit1[11] = 11731;
        expected_logit0[12] = 6332;  expected_logit1[12] = -3047;
        expected_logit0[13] = -8669; expected_logit1[13] = 13583;
        expected_logit0[14] = 12106; expected_logit1[14] = -9431;
        expected_logit0[15] = -11941; expected_logit1[15] = 15673;

        errors = 0;
        #20;
        rst = 1'b0;
        #20;
        start = 1'b1;
        #10;
        start = 1'b0;

        wait(done);
        #1;
        if (logit0 !== expected_logit0[IMAGE]) begin
            errors = errors + 1;
            $display("FC logit0 image=%0d got=%0d exp=%0d",
                     IMAGE, logit0, expected_logit0[IMAGE]);
        end
        if (logit1 !== expected_logit1[IMAGE]) begin
            errors = errors + 1;
            $display("FC logit1 image=%0d got=%0d exp=%0d",
                     IMAGE, logit1, expected_logit1[IMAGE]);
        end
        $display("FC image=%0d logit0=%0d logit1=%0d errors=%0d",
                 IMAGE, logit0, logit1, errors);
        if (errors != 0)
            $display("*** TEST FAILED: tb_fc_layer ***");
        else
            $display("*** TEST PASSED: tb_fc_layer ***");
        $finish;
    end

    initial begin
        $dumpfile("tb_fc_layer.vcd");
        $dumpvars(0, tb_fc_layer);
    end
endmodule
