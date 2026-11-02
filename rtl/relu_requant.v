`timescale 1ns / 1ps
//==============================================================================
// relu_requant : ReLU + requantisation (arithmetic shift) + saturation
//
// Golden (quantize_export.py):  act = np.clip(acc >> S, 0, 127)
//   - acc  : signed accumulator, BIAS ALREADY ADDED (conv_pe output)
//   - >>>  : arithmetic shift, so a negative acc stays negative and clips to 0
//   - ReLU : negative -> 0   |   saturate : > SAT -> SAT (127 = uint7)
// Combinational, 0 latency.
// Layer 1 uses SHIFT = 10 (S1), layer 2 uses SHIFT = 6 (S2)  (export/params.txt)
//==============================================================================
module relu_requant #(
    parameter IN_W  = 32,
    parameter SHIFT = 10,
    parameter OUT_W = 8,
    parameter SAT   = 127
)(
    input  signed [IN_W-1:0] acc,
    output        [OUT_W-1:0] act_out
);
    localparam [OUT_W-1:0] SAT_V = SAT;

    wire signed [IN_W-1:0] shifted = acc >>> SHIFT;
    wire                   is_neg  = shifted[IN_W-1];
    wire                   is_sat  = ~is_neg & (shifted > SAT);

    assign act_out = is_neg ? {OUT_W{1'b0}} :
                     is_sat ? SAT_V         :
                              shifted[OUT_W-1:0];
endmodule
