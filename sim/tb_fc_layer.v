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
    wire [6:0] w_addr;
    reg signed [15:0] w_data;
    wire b_addr;
    reg signed [31:0] b_data;
    wire done;
    wire signed [31:0] logit0, logit1;

    integer i;
    integer errors;
    integer fd, parsed, row_slot, row_label, row_pred;
    reg [1023:0] header;

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
        w_data  <= {weight_mem[128 + w_addr], weight_mem[w_addr]};
        b_data  <= bias_mem[b_addr];
    end

    initial begin
        $readmemh("expected_a2.mem", a2_mem);
        $readmemh("fc_w.mem", weight_mem);
        $readmemh("fc_b.mem", bias_mem);

        // Load the current export instead of duplicating stale golden constants.
        fd = $fopen("expected.txt", "r");
        if (fd == 0) $fatal(1, "missing expected.txt");
        parsed = $fgets(header, fd);
        if (parsed == 0) $fatal(1, "missing expected.txt header");
        for (i = 0; i < 16; i = i + 1) begin
            parsed = $fscanf(fd, "%d %d %d %d %d\n", row_slot, row_label, row_pred,
                              expected_logit0[i], expected_logit1[i]);
            if (parsed != 5 || row_slot != i)
                $fatal(1, "invalid expected.txt row %0d", i);
        end
        $fclose(fd);
        if (IMAGE < 0 || IMAGE > 15) $fatal(1, "IMAGE outside 0..15");

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
