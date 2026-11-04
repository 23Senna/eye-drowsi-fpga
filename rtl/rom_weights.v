`timescale 1ns / 1ps
//==============================================================================
// rom_weights : weight / bias / image ROMs (all reads synchronous, 1 clock)
//
// Weights stay int8 and biases stay int32, one value per port.
// The weight ROMs are read "filter-parallel": ONE tap address is shared, and each
// filter / class has its own int8 data port for that tap:
//   conv1_w{0..3}_data : conv1_w[f*9  + tap]   tap 0..8     (f = 0..3)
//   conv2_w{0..7}_data : conv2_w[f*36 + tap]   tap 0..35    (f = 0..7)
//   fc_w{0,1}_data     : fc_w[c*128   + tap]   tap 0..127   (c = 0..1)
// The .mem files are unchanged (same layout as before).
// Biases keep one entry per read (the layers read them once at start).
//==============================================================================
module rom_weights (
    input clk,
    // Conv1 ROM
    input  [3:0]  conv1_w_addr,
    output reg signed [7:0] conv1_w0_data, conv1_w1_data, conv1_w2_data, conv1_w3_data,
    input  [1:0]  conv1_b_addr,
    output reg signed [31:0] conv1_b_data,

    // Conv2 ROM
    input  [5:0]  conv2_w_addr,
    output reg signed [7:0] conv2_w0_data, conv2_w1_data, conv2_w2_data, conv2_w3_data,
                            conv2_w4_data, conv2_w5_data, conv2_w6_data, conv2_w7_data,
    input  [2:0]  conv2_b_addr,
    output reg signed [31:0] conv2_b_data,

    // FC ROM
    input  [6:0]  fc_w_addr,
    output reg signed [7:0] fc_w0_data, fc_w1_data,
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

    wire [8:0] t1 = {5'd0, conv1_w_addr};
    wire [8:0] t2 = {3'd0, conv2_w_addr};
    wire [8:0] t3 = {2'd0, fc_w_addr};

    always @(posedge clk) begin
        conv1_w0_data <= conv1_w[t1];
        conv1_w1_data <= conv1_w[t1 + 9'd9];
        conv1_w2_data <= conv1_w[t1 + 9'd18];
        conv1_w3_data <= conv1_w[t1 + 9'd27];

        conv2_w0_data <= conv2_w[t2];
        conv2_w1_data <= conv2_w[t2 + 9'd36];
        conv2_w2_data <= conv2_w[t2 + 9'd72];
        conv2_w3_data <= conv2_w[t2 + 9'd108];
        conv2_w4_data <= conv2_w[t2 + 9'd144];
        conv2_w5_data <= conv2_w[t2 + 9'd180];
        conv2_w6_data <= conv2_w[t2 + 9'd216];
        conv2_w7_data <= conv2_w[t2 + 9'd252];

        fc_w0_data    <= fc_w[t3];
        fc_w1_data    <= fc_w[t3 + 9'd128];

        conv1_b_data <= conv1_b[conv1_b_addr];
        conv2_b_data <= conv2_b[conv2_b_addr];
        fc_b_data    <= fc_b[fc_b_addr];
        img_data     <= images[img_addr];
    end
endmodule