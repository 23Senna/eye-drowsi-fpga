`timescale 1ns / 1ps
//==============================================================================
// Unit test : relu_requant   (run with cwd = mem/ so $readmemh finds the files)
//   A) Python vectors (np.clip(acc >> S, 0, 127)) incl. every clip boundary
//   B) independent in-testbench model (no >>>) on 20000 random 32-bit values
//   C) directed checks of the three regions: negative / linear / saturated
//==============================================================================
module relu_chk #(parameter SHIFT = 10, parameter N = 4111,
                  parameter IN_F = "relu_s10_in.mem", parameter EXP_F = "relu_s10_exp.mem")
                 (output reg [31:0] errors, output reg [31:0] n_checked);
    reg [31:0] in_m  [0:N-1];
    reg [7:0]  exp_m [0:N-1];
    reg signed [31:0] acc;
    wire [7:0] act;
    relu_requant #(.IN_W(32), .SHIFT(SHIFT)) dut (.acc(acc), .act_out(act));

    integer k, q, fd;
    reg signed [31:0] r;
    reg [7:0] ref_v;
    initial begin
        errors = 0; n_checked = 0;
        fd = $fopen(IN_F, "r");
        if (fd == 0) $fatal(1, "missing input vectors: %0s", IN_F);
        $fclose(fd);
        fd = $fopen(EXP_F, "r");
        if (fd == 0) $fatal(1, "missing expected vectors: %0s", EXP_F);
        $fclose(fd);
        $readmemh(IN_F, in_m); $readmemh(EXP_F, exp_m);
        // A) python vectors
        for (k = 0; k < N; k = k + 1) begin
            if ((^in_m[k] === 1'bx) || (^exp_m[k] === 1'bx))
                $fatal(1, "unknown or incomplete vector at index %0d", k);
            acc = in_m[k]; #1;
            n_checked = n_checked + 1;
            if (act !== exp_m[k]) begin
                errors = errors + 1;
                if (errors < 10) $display("  [S=%0d][A] FAIL acc=%0d got=%0d exp=%0d", SHIFT, acc, act, exp_m[k]);
            end
        end
        // B) independent model: negative/zero -> 0 ; else min(127, acc / 2^SHIFT) (truncating divide == floor for acc>0)
        for (k = 0; k < 20000; k = k + 1) begin
            r = $random; acc = r; #1;
            if (r <= 0)                         ref_v = 8'd0;
            else if ((r / (1 << SHIFT)) > 127)  ref_v = 8'd127;
            else                                ref_v = r / (1 << SHIFT);
            n_checked = n_checked + 1;
            if (act !== ref_v) begin
                errors = errors + 1;
                if (errors < 10) $display("  [S=%0d][B] FAIL acc=%0d got=%0d ref=%0d", SHIFT, acc, act, ref_v);
            end
        end
        // C) directed
        acc = -32'sd1;                   #1; n_checked = n_checked + 1; if (act !== 8'd0)   begin errors = errors + 1; $display("  [S=%0d][C] FAIL acc=-1 -> %0d", SHIFT, act); end
        acc = 32'sd0;                    #1; n_checked = n_checked + 1; if (act !== 8'd0)   begin errors = errors + 1; $display("  [S=%0d][C] FAIL acc=0 -> %0d", SHIFT, act); end
        acc = (32'sd1 << SHIFT) - 1;     #1; n_checked = n_checked + 1; if (act !== 8'd0)   begin errors = errors + 1; $display("  [S=%0d][C] FAIL just below 1 LSB -> %0d", SHIFT, act); end
        acc = (32'sd1 << SHIFT);         #1; n_checked = n_checked + 1; if (act !== 8'd1)   begin errors = errors + 1; $display("  [S=%0d][C] FAIL 1 LSB -> %0d", SHIFT, act); end
        acc = (32'sd127 << SHIFT);       #1; n_checked = n_checked + 1; if (act !== 8'd127) begin errors = errors + 1; $display("  [S=%0d][C] FAIL 127 -> %0d", SHIFT, act); end
        acc = (32'sd128 << SHIFT);       #1; n_checked = n_checked + 1; if (act !== 8'd127) begin errors = errors + 1; $display("  [S=%0d][C] FAIL 128 saturate -> %0d", SHIFT, act); end
        acc = 32'sh7FFFFFFF;             #1; n_checked = n_checked + 1; if (act !== 8'd127) begin errors = errors + 1; $display("  [S=%0d][C] FAIL INT_MAX -> %0d", SHIFT, act); end
        acc = 32'sh80000000;             #1; n_checked = n_checked + 1; if (act !== 8'd0)   begin errors = errors + 1; $display("  [S=%0d][C] FAIL INT_MIN -> %0d", SHIFT, act); end
    end
endmodule

module tb_relu_requant;
    wire [31:0] e1, e2, n1, n2;
    relu_chk #(.SHIFT(10), .IN_F("relu_s10_in.mem"), .EXP_F("relu_s10_exp.mem")) u_s10 (.errors(e1), .n_checked(n1));
    relu_chk #(.SHIFT(6),  .IN_F("relu_s6_in.mem"),  .EXP_F("relu_s6_exp.mem"))  u_s6  (.errors(e2), .n_checked(n2));
    initial begin
        #200000;
        $display("relu_requant S=10 : %0d checks, %0d errors", n1, e1);
        $display("relu_requant S=6  : %0d checks, %0d errors", n2, e2);
        if (e1 + e2 == 0) $display("*** TEST PASSED : tb_relu_requant ***");
        else              $display("*** TEST FAILED : tb_relu_requant ***");
        $finish;
    end
endmodule
