// weight_bias_rom.v - CNN parameters (int8 weights, int32 biases), 1-cycle registered read on both ports.
// Files are built by scripts/gen_sim_data.py from the Python export (quantize_export.py).
// weights:  0-35    conv1  f*9 + ky*3 + kx                      (4 x 1 x 3 x 3)
//           36-323  conv2  36 + f2*36 + f1*9 + ky*3 + kx        (8 x 4 x 3 x 3)
//           324-579 fc     324 + class*128 + ch*16 + r*4 + c    (2 x 128, PyTorch flatten)
// biases:   0-3 conv1, 4-11 conv2, 12-13 fc (already in accumulator scale)
module weight_bias_rom #(
    parameter W_FILE  = "weights.mem",
    parameter B_FILE  = "biases.mem",
    parameter W_COUNT = 580,
    parameter B_COUNT = 14
) (
    input  wire        clk,
    input  wire [11:0] w_addr,
    output reg  [7:0]  w_data,
    input  wire [4:0]  b_addr,
    output reg  [31:0] b_data
);
    reg [7:0]  wmem [0:1023];
    reg [31:0] bmem [0:31];
    initial begin
        $readmemh(W_FILE, wmem, 0, W_COUNT - 1);
        $readmemh(B_FILE, bmem, 0, B_COUNT - 1);
    end
    always @(posedge clk) begin
        w_data <= wmem[w_addr[9:0]];
        b_data <= bmem[b_addr];
    end
endmodule
