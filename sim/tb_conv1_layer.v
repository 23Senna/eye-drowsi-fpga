`timescale 1ns / 1ps

// Run from ml/export so the $readmemh file names resolve.
// Override IMAGE with: iverilog -Ptb_conv1_layer.IMAGE=3 ...
module tb_conv1_layer #(
    parameter integer IMAGE = 0
);
    reg clk = 1'b0;
    reg rst = 1'b1;
    reg start = 1'b0;

    reg [7:0] image_mem [0:16383];
    reg signed [7:0] weight_mem [0:35];
    reg signed [31:0] bias_mem [0:3];
    reg [7:0] expected_mem [0:7743];
    reg [7:0] got_mem [0:483];

    wire [9:0] img_addr;
    reg [7:0] img_data;
    wire [5:0] w_addr;
    reg signed [7:0] w_data;
    wire [1:0] b_addr;
    reg signed [31:0] b_data;
    wire done, a1_we;
    wire [8:0] a1_waddr;
    wire [7:0] a1_wdata;

    integer i;
    integer errors;
    integer writes;

    always #5 clk = ~clk;

    conv1_layer dut (
        .clk(clk), .rst(rst), .start(start), .done(done),
        .img_addr(img_addr), .img_data(img_data),
        .w_addr(w_addr), .w_data(w_data),
        .b_addr(b_addr), .b_data(b_data),
        .a1_we(a1_we), .a1_waddr(a1_waddr), .a1_wdata(a1_wdata)
    );

    // Synchronous input memories, matching rom_weights.v.
    always @(posedge clk) begin
        img_data <= image_mem[IMAGE * 1024 + img_addr];
        w_data   <= weight_mem[w_addr];
        b_data   <= bias_mem[b_addr];
        if (a1_we) begin
            got_mem[a1_waddr] <= a1_wdata;
            writes <= writes + 1;
        end
    end

    initial begin
        $readmemh("images.mem", image_mem);
        $readmemh("conv1_w.mem", weight_mem);
        $readmemh("conv1_b.mem", bias_mem);
        $readmemh("expected_a1.mem", expected_mem);
        writes = 0;
        errors = 0;
        for (i = 0; i < 484; i = i + 1)
            got_mem[i] = 8'hxx;

        #20;
        rst = 1'b0;
        #20;
        start = 1'b1;
        #10;
        start = 1'b0;

        wait(done);
        #1;
        for (i = 0; i < 484; i = i + 1) begin
            if (got_mem[i] !== expected_mem[IMAGE * 484 + i]) begin
                errors = errors + 1;
                if (errors < 10)
                    $display("L1 mismatch image=%0d index=%0d got=%0d exp=%0d",
                             IMAGE, i, got_mem[i], expected_mem[IMAGE * 484 + i]);
            end
        end
        $display("L1 image=%0d writes=%0d errors=%0d", IMAGE, writes, errors);
        if (writes != 484 || errors != 0)
            $display("*** TEST FAILED: tb_conv1_layer ***");
        else
            $display("*** TEST PASSED: tb_conv1_layer ***");
        $finish;
    end

    initial begin
        $dumpfile("tb_conv1_layer.vcd");
        $dumpvars(0, tb_conv1_layer);
    end
endmodule
