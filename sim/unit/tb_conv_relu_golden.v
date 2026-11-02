`timescale 1ns / 1ps
//==============================================================================
// Golden test : conv_pe + relu_requant  vs  the team's expected_a1.mem / expected_a2.mem
//   Layer 1 : real conv1 weights, real images -> conv_pe(9)  -> relu(S1) -> 2x2 max -> a1 (4x11x11)
//   Layer 2 : GOLDEN a1 as input (isolated from layer 1) -> conv_pe(36) -> relu(S2) -> 2x2 max -> a2 (8x4x4)
//   16 images, every pooled output compared. 2x2 max-pool is done in the testbench only
//   (pool is not part of this task, it is just the observation point of the golden file).
//==============================================================================
module tb_conv_relu_golden;
    reg clk = 0, rst = 1;
    always #5 clk = ~clk;

    reg [7:0]  w1m [0:35];   reg [31:0] b1m [0:3];
    reg [7:0]  w2m [0:287];  reg [31:0] b2m [0:7];
    reg [7:0]  img [0:16383];
    reg [7:0]  ea1 [0:7743];            // 16 * 4*11*11
    reg [7:0]  ea2 [0:2047];            // 16 * 8*4*4

    // layer-1 datapath
    reg v1;  reg [8*9-1:0] pix1, wf1;  reg signed [31:0] bias1;
    wire ov1; wire signed [31:0] acc1; wire [7:0] act1;
    conv_pe #(.NTAPS(9)) c1 (.clk(clk), .rst(rst), .in_valid(v1), .pix_flat(pix1), .w_flat(wf1), .bias(bias1), .out_valid(ov1), .acc(acc1));
    relu_requant #(.IN_W(32), .SHIFT(10)) r1 (.acc(acc1), .act_out(act1));

    // layer-2 datapath
    reg v2;  reg [8*36-1:0] pix2, wf2;  reg signed [31:0] bias2;
    wire ov2; wire signed [31:0] acc2; wire [7:0] act2;
    conv_pe #(.NTAPS(36)) c2 (.clk(clk), .rst(rst), .in_valid(v2), .pix_flat(pix2), .w_flat(wf2), .bias(bias2), .out_valid(ov2), .acc(acc2));
    relu_requant #(.IN_W(32), .SHIFT(6)) r2 (.acc(acc2), .act_out(act2));

    integer errors1, errors2, checks1, checks2, neg1, sat1, neg2, sat2, zero1, zero2;
    integer n, f, orr, oc, pr, pc, ch, ky, kx, t, mx;
    reg [7:0] got;

    // one conv1 window -> relu output (2 clocks latency)
    task win1; input integer ni, fi, r, c;
        integer a, b, kk;
        begin
            @(negedge clk);
            for (a = 0; a < 3; a = a + 1)
                for (b = 0; b < 3; b = b + 1) begin
                    kk = a*3 + b;
                    pix1[8*kk +: 8] = img[ni*1024 + (r+a)*24 + (c+b)];
                    wf1 [8*kk +: 8] = w1m[fi*9 + kk];
                end
            bias1 = b1m[fi]; v1 = 1;
            @(negedge clk); v1 = 0;
            @(negedge clk);
            if (!ov1) begin errors1 = errors1 + 1; $display("  FAIL conv1 out_valid missing"); end
            got = act1;
            if (acc1 < 0) neg1 = neg1 + 1;
            if ((acc1 >>> 10) > 127) sat1 = sat1 + 1;
        end
    endtask

    // one conv2 window -> relu output
    task win2; input integer ni, fi, r, c;
        integer cc, a, b, tt;
        begin
            @(negedge clk);
            for (cc = 0; cc < 4; cc = cc + 1)
                for (a = 0; a < 3; a = a + 1)
                    for (b = 0; b < 3; b = b + 1) begin
                        tt = cc*9 + a*3 + b;
                        pix2[8*tt +: 8] = ea1[ni*484 + cc*121 + (r+a)*11 + (c+b)];
                        wf2 [8*tt +: 8] = w2m[fi*36 + tt];
                    end
            bias2 = b2m[fi]; v2 = 1;
            @(negedge clk); v2 = 0;
            @(negedge clk);
            if (!ov2) begin errors2 = errors2 + 1; $display("  FAIL conv2 out_valid missing"); end
            got = act2;
            if (acc2 < 0) neg2 = neg2 + 1;
            if ((acc2 >>> 7) > 127) sat2 = sat2 + 1;
        end
    endtask

    initial begin
        errors1 = 0; errors2 = 0; checks1 = 0; checks2 = 0; neg1 = 0; sat1 = 0; neg2 = 0; sat2 = 0; zero1 = 0; zero2 = 0;
        v1 = 0; v2 = 0; pix1 = 0; wf1 = 0; bias1 = 0; pix2 = 0; wf2 = 0; bias2 = 0;
        $readmemh("conv1_w.mem", w1m); $readmemh("conv1_b.mem", b1m);
        $readmemh("conv2_w.mem", w2m); $readmemh("conv2_b.mem", b2m);
        $readmemh("images.mem", img);
        $readmemh("expected_a1.mem", ea1); $readmemh("expected_a2.mem", ea2);
        repeat (4) @(negedge clk); rst = 0; repeat (2) @(negedge clk);

        // ---------------- layer 1
        for (n = 0; n < 16; n = n + 1)
          for (f = 0; f < 4; f = f + 1)
            for (orr = 0; orr < 11; orr = orr + 1)
              for (oc = 0; oc < 11; oc = oc + 1) begin
                  mx = 0;
                  for (pr = 0; pr < 2; pr = pr + 1)
                    for (pc = 0; pc < 2; pc = pc + 1) begin
                        win1(n, f, 2*orr + pr, 2*oc + pc);
                        if (got > mx) mx = got;
                    end
                  checks1 = checks1 + 1;
                  if (mx == 0) zero1 = zero1 + 1;
                  if (mx[7:0] !== ea1[n*484 + f*121 + orr*11 + oc]) begin
                      errors1 = errors1 + 1;
                      if (errors1 < 10) $display("  FAIL L1 img%0d f%0d (%0d,%0d) got=%0d exp=%0d", n, f, orr, oc, mx, ea1[n*484 + f*121 + orr*11 + oc]);
                  end
              end

        // ---------------- layer 2
        for (n = 0; n < 16; n = n + 1)
          for (f = 0; f < 8; f = f + 1)
            for (orr = 0; orr < 4; orr = orr + 1)
              for (oc = 0; oc < 4; oc = oc + 1) begin
                  mx = 0;
                  for (pr = 0; pr < 2; pr = pr + 1)
                    for (pc = 0; pc < 2; pc = pc + 1) begin
                        win2(n, f, 2*orr + pr, 2*oc + pc);
                        if (got > mx) mx = got;
                    end
                  checks2 = checks2 + 1;
                  if (mx == 0) zero2 = zero2 + 1;
                  if (mx[7:0] !== ea2[n*128 + f*16 + orr*4 + oc]) begin
                      errors2 = errors2 + 1;
                      if (errors2 < 10) $display("  FAIL L2 img%0d f%0d (%0d,%0d) got=%0d exp=%0d", n, f, orr, oc, mx, ea2[n*128 + f*16 + orr*4 + oc]);
                  end
              end

        $display("Layer 1 (conv_pe 9 taps  + ReLU S1=10): %0d pooled outputs, %0d errors | windows acc<0: %0d, saturated: %0d, pooled==0: %0d", checks1, errors1, neg1, sat1, zero1);
        $display("Layer 2 (conv_pe 36 taps + ReLU S2=6 ): %0d pooled outputs, %0d errors | windows acc<0: %0d, saturated: %0d, pooled==0: %0d", checks2, errors2, neg2, sat2, zero2);
        if (errors1 + errors2 == 0) $display("*** TEST PASSED : tb_conv_relu_golden ***");
        else                        $display("*** TEST FAILED : tb_conv_relu_golden ***");
        $finish;
    end
    initial begin #900000000; $display("*** TEST FAILED : tb_conv_relu_golden TIMEOUT ***"); $finish; end
endmodule
