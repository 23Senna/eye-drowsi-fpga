`timescale 1ns / 1ps
//==============================================================================
// rom_weights_150 : weight / bias / image ROMs for the 150 MHz core
//
// Same ports and same .mem files as rom_weights. What changed:
//
//  * Weights: the "base address + constant offset" adder is no longer in front of
//    the ROM read. Every weight port has its own address register, then the ROM
//    read register, then an output register:
//        w_addr valid (cycle n) -> port address reg (n+1) -> ROM data (n+2) -> output (n+3)
//    so weight data is valid 3 clocks after the layer's w_addr (was 1 clock).
//    The extra output register is the one a block RAM absorbs as its DOREG.
//  * Biases and image: unchanged (1 clock). Biases are only read at layer start,
//    the image ROM is read by the loader in the top.
//
// The ROM contents / layout are identical to rom_weights:
//   conv1_w[f*9 + tap], conv2_w[f*36 + tap], fc_w[c*128 + tap]
//==============================================================================
module rom_weights_150 (
    input clk,
    // Conv1 ROM
    input  [3:0]  conv1_w_addr,
    output reg signed [7:0] conv1_w0_data, conv1_w1_data, conv1_w2_data, conv1_w3_data,
    output reg signed [7:0] conv1_wL1_0_data, conv1_wL1_1_data, conv1_wL1_2_data, conv1_wL1_3_data,
    output reg signed [7:0] conv1_wL2_0_data, conv1_wL2_1_data, conv1_wL2_2_data, conv1_wL2_3_data,
    input  [1:0]  conv1_b_addr,
    output reg signed [31:0] conv1_b_data,

    // Conv2 ROM
    input  [5:0]  conv2_w_addr,
    output reg signed [7:0] conv2_w0_data, conv2_w1_data, conv2_w2_data, conv2_w3_data,
                            conv2_w4_data, conv2_w5_data, conv2_w6_data, conv2_w7_data,
    output reg signed [7:0] conv2_wB0_data, conv2_wB1_data, conv2_wB2_data, conv2_wB3_data,
                            conv2_wB4_data, conv2_wB5_data, conv2_wB6_data, conv2_wB7_data,
    input  [2:0]  conv2_b_addr,
    output reg signed [31:0] conv2_b_data,

    // FC ROM
    input  [6:0]  fc_w_addr,
    output reg signed [7:0] fc_w0_data, fc_w1_data, fc_w2_data, fc_w3_data,
                            fc_w4_data, fc_w5_data, fc_w6_data, fc_w7_data,
    input         fc_b_addr,
    output reg signed [31:0] fc_b_data,

    // Image RAM/ROM
    input  [13:0] img_addr,
    output reg [7:0] img_data
);

    reg signed [7:0]  conv1_w [0:35];
    reg signed [31:0] conv1_b [0:3];
    reg signed [7:0]  conv2_w [0:287];
    reg signed [31:0] conv2_b [0:7];
    reg signed [7:0]  fc_w    [0:255];
    reg signed [31:0] fc_b    [0:1];
    reg        [7:0]  images  [0:16383];

    initial begin
        $readmemh("conv1_w.mem", conv1_w);
        $readmemh("conv1_b.mem", conv1_b);
        $readmemh("conv2_w.mem", conv2_w);
        $readmemh("conv2_b.mem", conv2_b);
        $readmemh("fc_w.mem",    fc_w);
        $readmemh("fc_b.mem",    fc_b);
        $readmemh("images.mem",  images);
    end

    // ---- per-port address / ROM-read registers
    reg [5:0] conv1_w0_data_a;
    reg signed [7:0] conv1_w0_data_m;
    reg [5:0] conv1_w1_data_a;
    reg signed [7:0] conv1_w1_data_m;
    reg [5:0] conv1_w2_data_a;
    reg signed [7:0] conv1_w2_data_m;
    reg [5:0] conv1_w3_data_a;
    reg signed [7:0] conv1_w3_data_m;
    reg [5:0] conv1_wL1_0_data_a;
    reg signed [7:0] conv1_wL1_0_data_m;
    reg [5:0] conv1_wL1_1_data_a;
    reg signed [7:0] conv1_wL1_1_data_m;
    reg [5:0] conv1_wL1_2_data_a;
    reg signed [7:0] conv1_wL1_2_data_m;
    reg [5:0] conv1_wL1_3_data_a;
    reg signed [7:0] conv1_wL1_3_data_m;
    reg [5:0] conv1_wL2_0_data_a;
    reg signed [7:0] conv1_wL2_0_data_m;
    reg [5:0] conv1_wL2_1_data_a;
    reg signed [7:0] conv1_wL2_1_data_m;
    reg [5:0] conv1_wL2_2_data_a;
    reg signed [7:0] conv1_wL2_2_data_m;
    reg [5:0] conv1_wL2_3_data_a;
    reg signed [7:0] conv1_wL2_3_data_m;
    reg [8:0] conv2_w0_data_a;
    reg signed [7:0] conv2_w0_data_m;
    reg [8:0] conv2_w1_data_a;
    reg signed [7:0] conv2_w1_data_m;
    reg [8:0] conv2_w2_data_a;
    reg signed [7:0] conv2_w2_data_m;
    reg [8:0] conv2_w3_data_a;
    reg signed [7:0] conv2_w3_data_m;
    reg [8:0] conv2_w4_data_a;
    reg signed [7:0] conv2_w4_data_m;
    reg [8:0] conv2_w5_data_a;
    reg signed [7:0] conv2_w5_data_m;
    reg [8:0] conv2_w6_data_a;
    reg signed [7:0] conv2_w6_data_m;
    reg [8:0] conv2_w7_data_a;
    reg signed [7:0] conv2_w7_data_m;
    reg [8:0] conv2_wB0_data_a;
    reg signed [7:0] conv2_wB0_data_m;
    reg [8:0] conv2_wB1_data_a;
    reg signed [7:0] conv2_wB1_data_m;
    reg [8:0] conv2_wB2_data_a;
    reg signed [7:0] conv2_wB2_data_m;
    reg [8:0] conv2_wB3_data_a;
    reg signed [7:0] conv2_wB3_data_m;
    reg [8:0] conv2_wB4_data_a;
    reg signed [7:0] conv2_wB4_data_m;
    reg [8:0] conv2_wB5_data_a;
    reg signed [7:0] conv2_wB5_data_m;
    reg [8:0] conv2_wB6_data_a;
    reg signed [7:0] conv2_wB6_data_m;
    reg [8:0] conv2_wB7_data_a;
    reg signed [7:0] conv2_wB7_data_m;
    reg [7:0] fc_w0_data_a;
    reg signed [7:0] fc_w0_data_m;
    reg [7:0] fc_w1_data_a;
    reg signed [7:0] fc_w1_data_m;
    reg [7:0] fc_w2_data_a;
    reg signed [7:0] fc_w2_data_m;
    reg [7:0] fc_w3_data_a;
    reg signed [7:0] fc_w3_data_m;
    reg [7:0] fc_w4_data_a;
    reg signed [7:0] fc_w4_data_m;
    reg [7:0] fc_w5_data_a;
    reg signed [7:0] fc_w5_data_m;
    reg [7:0] fc_w6_data_a;
    reg signed [7:0] fc_w6_data_m;
    reg [7:0] fc_w7_data_a;
    reg signed [7:0] fc_w7_data_m;

    always @(posedge clk) begin
        // conv1 (base address + offset registered first, then ROM read, then output reg)
        conv1_w0_data_a <= conv1_w_addr + 6'd0;
        conv1_w0_data_m <= conv1_w[conv1_w0_data_a];
        conv1_w0_data <= conv1_w0_data_m;
        conv1_w1_data_a <= conv1_w_addr + 6'd9;
        conv1_w1_data_m <= conv1_w[conv1_w1_data_a];
        conv1_w1_data <= conv1_w1_data_m;
        conv1_w2_data_a <= conv1_w_addr + 6'd18;
        conv1_w2_data_m <= conv1_w[conv1_w2_data_a];
        conv1_w2_data <= conv1_w2_data_m;
        conv1_w3_data_a <= conv1_w_addr + 6'd27;
        conv1_w3_data_m <= conv1_w[conv1_w3_data_a];
        conv1_w3_data <= conv1_w3_data_m;
        conv1_wL1_0_data_a <= conv1_w_addr + 6'd1;
        conv1_wL1_0_data_m <= conv1_w[conv1_wL1_0_data_a];
        conv1_wL1_0_data <= conv1_wL1_0_data_m;
        conv1_wL1_1_data_a <= conv1_w_addr + 6'd10;
        conv1_wL1_1_data_m <= conv1_w[conv1_wL1_1_data_a];
        conv1_wL1_1_data <= conv1_wL1_1_data_m;
        conv1_wL1_2_data_a <= conv1_w_addr + 6'd19;
        conv1_wL1_2_data_m <= conv1_w[conv1_wL1_2_data_a];
        conv1_wL1_2_data <= conv1_wL1_2_data_m;
        conv1_wL1_3_data_a <= conv1_w_addr + 6'd28;
        conv1_wL1_3_data_m <= conv1_w[conv1_wL1_3_data_a];
        conv1_wL1_3_data <= conv1_wL1_3_data_m;
        conv1_wL2_0_data_a <= conv1_w_addr + 6'd2;
        conv1_wL2_0_data_m <= conv1_w[conv1_wL2_0_data_a];
        conv1_wL2_0_data <= conv1_wL2_0_data_m;
        conv1_wL2_1_data_a <= conv1_w_addr + 6'd11;
        conv1_wL2_1_data_m <= conv1_w[conv1_wL2_1_data_a];
        conv1_wL2_1_data <= conv1_wL2_1_data_m;
        conv1_wL2_2_data_a <= conv1_w_addr + 6'd20;
        conv1_wL2_2_data_m <= conv1_w[conv1_wL2_2_data_a];
        conv1_wL2_2_data <= conv1_wL2_2_data_m;
        conv1_wL2_3_data_a <= conv1_w_addr + 6'd29;
        conv1_wL2_3_data_m <= conv1_w[conv1_wL2_3_data_a];
        conv1_wL2_3_data <= conv1_wL2_3_data_m;
        // conv2
        conv2_w0_data_a <= conv2_w_addr + 9'd0;
        conv2_w0_data_m <= conv2_w[conv2_w0_data_a];
        conv2_w0_data <= conv2_w0_data_m;
        conv2_w1_data_a <= conv2_w_addr + 9'd36;
        conv2_w1_data_m <= conv2_w[conv2_w1_data_a];
        conv2_w1_data <= conv2_w1_data_m;
        conv2_w2_data_a <= conv2_w_addr + 9'd72;
        conv2_w2_data_m <= conv2_w[conv2_w2_data_a];
        conv2_w2_data <= conv2_w2_data_m;
        conv2_w3_data_a <= conv2_w_addr + 9'd108;
        conv2_w3_data_m <= conv2_w[conv2_w3_data_a];
        conv2_w3_data <= conv2_w3_data_m;
        conv2_w4_data_a <= conv2_w_addr + 9'd144;
        conv2_w4_data_m <= conv2_w[conv2_w4_data_a];
        conv2_w4_data <= conv2_w4_data_m;
        conv2_w5_data_a <= conv2_w_addr + 9'd180;
        conv2_w5_data_m <= conv2_w[conv2_w5_data_a];
        conv2_w5_data <= conv2_w5_data_m;
        conv2_w6_data_a <= conv2_w_addr + 9'd216;
        conv2_w6_data_m <= conv2_w[conv2_w6_data_a];
        conv2_w6_data <= conv2_w6_data_m;
        conv2_w7_data_a <= conv2_w_addr + 9'd252;
        conv2_w7_data_m <= conv2_w[conv2_w7_data_a];
        conv2_w7_data <= conv2_w7_data_m;
        conv2_wB0_data_a <= conv2_w_addr + 9'd9;
        conv2_wB0_data_m <= conv2_w[conv2_wB0_data_a];
        conv2_wB0_data <= conv2_wB0_data_m;
        conv2_wB1_data_a <= conv2_w_addr + 9'd45;
        conv2_wB1_data_m <= conv2_w[conv2_wB1_data_a];
        conv2_wB1_data <= conv2_wB1_data_m;
        conv2_wB2_data_a <= conv2_w_addr + 9'd81;
        conv2_wB2_data_m <= conv2_w[conv2_wB2_data_a];
        conv2_wB2_data <= conv2_wB2_data_m;
        conv2_wB3_data_a <= conv2_w_addr + 9'd117;
        conv2_wB3_data_m <= conv2_w[conv2_wB3_data_a];
        conv2_wB3_data <= conv2_wB3_data_m;
        conv2_wB4_data_a <= conv2_w_addr + 9'd153;
        conv2_wB4_data_m <= conv2_w[conv2_wB4_data_a];
        conv2_wB4_data <= conv2_wB4_data_m;
        conv2_wB5_data_a <= conv2_w_addr + 9'd189;
        conv2_wB5_data_m <= conv2_w[conv2_wB5_data_a];
        conv2_wB5_data <= conv2_wB5_data_m;
        conv2_wB6_data_a <= conv2_w_addr + 9'd225;
        conv2_wB6_data_m <= conv2_w[conv2_wB6_data_a];
        conv2_wB6_data <= conv2_wB6_data_m;
        conv2_wB7_data_a <= conv2_w_addr + 9'd261;
        conv2_wB7_data_m <= conv2_w[conv2_wB7_data_a];
        conv2_wB7_data <= conv2_wB7_data_m;
        // fc
        fc_w0_data_a <= fc_w_addr + 8'd0;
        fc_w0_data_m <= fc_w[fc_w0_data_a];
        fc_w0_data <= fc_w0_data_m;
        fc_w1_data_a <= fc_w_addr + 8'd1;
        fc_w1_data_m <= fc_w[fc_w1_data_a];
        fc_w1_data <= fc_w1_data_m;
        fc_w2_data_a <= fc_w_addr + 8'd2;
        fc_w2_data_m <= fc_w[fc_w2_data_a];
        fc_w2_data <= fc_w2_data_m;
        fc_w3_data_a <= fc_w_addr + 8'd3;
        fc_w3_data_m <= fc_w[fc_w3_data_a];
        fc_w3_data <= fc_w3_data_m;
        fc_w4_data_a <= fc_w_addr + 8'd128;
        fc_w4_data_m <= fc_w[fc_w4_data_a];
        fc_w4_data <= fc_w4_data_m;
        fc_w5_data_a <= fc_w_addr + 8'd129;
        fc_w5_data_m <= fc_w[fc_w5_data_a];
        fc_w5_data <= fc_w5_data_m;
        fc_w6_data_a <= fc_w_addr + 8'd130;
        fc_w6_data_m <= fc_w[fc_w6_data_a];
        fc_w6_data <= fc_w6_data_m;
        fc_w7_data_a <= fc_w_addr + 8'd131;
        fc_w7_data_m <= fc_w[fc_w7_data_a];
        fc_w7_data <= fc_w7_data_m;

        // biases / image: 1 clock, as before
        conv1_b_data <= conv1_b[conv1_b_addr];
        conv2_b_data <= conv2_b[conv2_b_addr];
        fc_b_data    <= fc_b[fc_b_addr];
        img_data     <= images[img_addr];
    end
endmodule