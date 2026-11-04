`timescale 1ns / 1ps

module rom_weights (
    input clk,
    // Conv1 ROM
    input  [3:0]  conv1_w_addr,
    output reg signed [31:0] conv1_w_data,
    input  [1:0]  conv1_b_addr,
    output reg signed [31:0] conv1_b_data,

    // Conv2 ROM
    input  [5:0]  conv2_w_addr,
    output reg signed [63:0] conv2_w_data,
    input  [2:0]  conv2_b_addr,
    output reg signed [31:0] conv2_b_data,

    // FC ROM
    input  [6:0]  fc_w_addr,
    output reg signed [15:0] fc_w_data,
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

    always @(posedge clk) begin
        conv1_w_data <= {
            conv1_w[27 + conv1_w_addr],
            conv1_w[18 + conv1_w_addr],
            conv1_w[9  + conv1_w_addr],
            conv1_w[conv1_w_addr]
        };
        conv1_b_data <= conv1_b[conv1_b_addr];
        conv2_w_data <= {
            conv2_w[252 + conv2_w_addr],
            conv2_w[216 + conv2_w_addr],
            conv2_w[180 + conv2_w_addr],
            conv2_w[144 + conv2_w_addr],
            conv2_w[108 + conv2_w_addr],
            conv2_w[72  + conv2_w_addr],
            conv2_w[36  + conv2_w_addr],
            conv2_w[conv2_w_addr]
        };
        conv2_b_data <= conv2_b[conv2_b_addr];
        fc_w_data    <= {fc_w[128 + fc_w_addr], fc_w[fc_w_addr]};
        fc_b_data    <= fc_b[fc_b_addr];
        img_data     <= images[img_addr];
    end
endmodule