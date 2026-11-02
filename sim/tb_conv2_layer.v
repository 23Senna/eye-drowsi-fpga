`timescale 1ns / 1ps

// Run from ml/export so the $readmemh file names resolve.
module tb_conv2_layer #(
    parameter integer IMAGE = 0
);
    reg clk = 1'b0;
    reg rst = 1'b1;
    reg start = 1'b0;

    reg [7:0] a1_mem [0:7743];
    reg signed [7:0] weight_mem [0:287];
    reg signed [31:0] bias_mem [0:7];
    reg [7:0] expected_mem [0:2047];
    reg [7:0] got_mem [0:127];

    wire [8:0] a1_addr;
    reg [7:0] a1_data;
    wire [8:0] w_addr;
    reg signed [7:0] w_data;
    wire [2:0] b_addr;
    reg signed [31:0] b_data;
    wire done, a2_we;
    wire [6:0] a2_waddr;
    wire [7:0] a2_wdata;

    integer i;
    integer errors;
    integer writes;

    always #5 clk = ~clk;

    conv2_layer dut (
        .clk(clk), .rst(rst), .start(start), .done(done),
        .a1_addr(a1_addr), .a1_data(a1_data),
        .w_addr(w_addr), .w_data(w_data),
        .b_addr(b_addr), .b_data(b_data),
        .a2_we(a2_we), .a2_waddr(a2_waddr), .a2_wdata(a2_wdata)
    );

    always @(posedge clk) begin
        a1_data <= a1_mem[IMAGE * 484 + a1_addr];
        w_data  <= weight_mem[w_addr];
        b_data  <= bias_mem[b_addr];
        if (a2_we) begin
            got_mem[a2_waddr] <= a2_wdata;
            writes <= writes + 1;
        end
    end

    initial begin
        $readmemh("expected_a1.mem", a1_mem);
        $readmemh("conv2_w.mem", weight_mem);
        $readmemh("conv2_b.mem", bias_mem);
        $readmemh("expected_a2.mem", expected_mem);
        writes = 0;
        errors = 0;
        for (i = 0; i < 128; i = i + 1)
            got_mem[i] = 8'hxx;

        #20;
        rst = 1'b0;
        #20;
        start = 1'b1;
        #10;
        start = 1'b0;

        wait(done);
        #1;
        for (i = 0; i < 128; i = i + 1) begin
            if (got_mem[i] !== expected_mem[IMAGE * 128 + i]) begin
                errors = errors + 1;
                if (errors < 10)
                    $display("L2 mismatch image=%0d index=%0d got=%0d exp=%0d",
                             IMAGE, i, got_mem[i], expected_mem[IMAGE * 128 + i]);
            end
        end
        $display("L2 image=%0d writes=%0d errors=%0d", IMAGE, writes, errors);
        if (writes != 128 || errors != 0)
            $display("*** TEST FAILED: tb_conv2_layer ***");
        else
            $display("*** TEST PASSED: tb_conv2_layer ***");
        $finish;
    end

    initial begin
        $dumpfile("tb_conv2_layer.vcd");
        $dumpvars(0, tb_conv2_layer);
    end
endmodule
