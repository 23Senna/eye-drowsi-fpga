`timescale 1ns / 1ps

module tb_cnn;
    reg clk;
    reg rst;
    reg start;
    reg [13:0] img_base_addr;

    wire done;
    wire prediction;
    wire signed [31:0] logit0, logit1;

    cnn_top uut (
        .clk(clk),
        .rst(rst),
        .start(start),
        .img_base_addr(img_base_addr),
        .done(done),
        .prediction(prediction),
        .logit0(logit0),
        .logit1(logit1)
    );

    always #5 clk = ~clk; // 100MHz clock

    integer img_i;
    integer correct_count;
    integer errors;
    integer fd;
    integer parsed;
    integer row_slot;
    integer row_label;
    integer row_pred;
    integer expected_logit0 [0:15];
    integer expected_logit1 [0:15];
    reg expected_label [0:15];
    reg expected_prediction_mem [0:15];
    reg expected_prediction;
    reg [1023:0] header;

    initial begin
        clk = 0;
        rst = 1;
        start = 0;
        img_base_addr = 0;
        correct_count = 0;
        errors = 0;

        fd = $fopen("expected.txt", "r");
        if (fd == 0) $fatal(1, "missing expected.txt");
        parsed = $fgets(header, fd);
        if (parsed == 0) $fatal(1, "missing expected.txt header");
        for (img_i = 0; img_i < 16; img_i = img_i + 1) begin
            parsed = $fscanf(fd, "%d %d %d %d %d\n",
                             row_slot, row_label, row_pred,
                             expected_logit0[img_i],
                             expected_logit1[img_i]);
            if (parsed != 5 || row_slot != img_i)
                $fatal(1, "invalid expected.txt row %0d", img_i);
            expected_label[img_i] = row_label;
            if (row_pred != 0 && row_pred != 1)
                $fatal(1, "invalid prediction in expected.txt row %0d", img_i);
            expected_prediction_mem[img_i] = row_pred;
        end
        $fclose(fd);

        #100;
        rst = 0;
        #50;

        $display("====================================================");
        $display("   Starting CNN Eye Drowsiness Detection Simulation ");
        $display("====================================================");

        for (img_i = 0; img_i < 16; img_i = img_i + 1) begin
            img_base_addr = img_i * 1024;
            #20;
            start = 1;
            #10;
            start = 0;

            wait(done);
            #20;

            expected_prediction = expected_prediction_mem[img_i];
            if (prediction !== expected_prediction) begin
                errors = errors + 1;
                $display("CNN image %2d | prediction mismatch | got=%0d exp=%0d",
                         img_i, prediction, expected_prediction);
            end
            if (logit0 !== expected_logit0[img_i]) begin
                errors = errors + 1;
                $display("CNN image %2d | logit0 mismatch | got=%0d exp=%0d",
                         img_i, logit0, expected_logit0[img_i]);
            end
            if (logit1 !== expected_logit1[img_i]) begin
                errors = errors + 1;
                $display("CNN image %2d | logit1 mismatch | got=%0d exp=%0d",
                         img_i, logit1, expected_logit1[img_i]);
            end

            if (prediction == expected_prediction &&
                logit0 == expected_logit0[img_i] &&
                logit1 == expected_logit1[img_i]) begin
                correct_count = correct_count + 1;
                $display("Image %2d | Expected: %s | Pred: %s | CORRECT | Logit0: %0d | Logit1: %0d",
                         img_i, expected_prediction ? "OPEN  " : "CLOSED",
                         prediction ? "OPEN  " : "CLOSED", logit0, logit1);
            end else begin
                $display("Image %2d | Expected: %s | Pred: %s | WRONG   | Logit0: %0d | Logit1: %0d",
                         img_i, expected_prediction ? "OPEN  " : "CLOSED",
                         prediction ? "OPEN  " : "CLOSED", logit0, logit1);
            end
        end

        $display("====================================================");
        $display("   Classification accuracy: %0d / 16", correct_count);
        $display("   Total mismatches: %0d", errors);
        $display("====================================================");
        if (errors == 0)
            $display("*** TEST PASSED: tb_cnn ***");
        else
            $display("*** TEST FAILED: tb_cnn ***");
        $display("====================================================");
        $finish;
    end

    initial begin
        $dumpfile("tb_cnn.vcd");
        $dumpvars(0, tb_cnn);
    end
endmodule