`timescale 1ns / 1ps
//==============================================================================
// mac_pipe_lut : same function / same latency as mac_pipe, but the multiplier
// (and the accumulator adder) are forced into LUT fabric instead of a DSP48.
//
//   cycle k   : a (uint8), w (int8), bias (int32), first  presented together
//   cycle k+1 : prod = a * w                       (LUTs)
//   cycle k+2 : acc  = (first ? bias : acc) + prod (acc includes this tap)
//
// Used to add MAC parallelism without spending DSP blocks.
//==============================================================================
(* use_dsp = "no" *)
module mac_pipe_lut (
    input                    clk,
    input      [7:0]         a,
    input  signed [7:0]      w,
    input  signed [31:0]     bias,
    input                    first,
    output reg signed [31:0] acc
);
    (* use_dsp48 = "no" *) reg signed [16:0] prod;
    reg signed [31:0] bias_q;
    reg               first_q;

    always @(posedge clk) begin
        prod    <= $signed({1'b0, a}) * w;
        bias_q  <= bias;
        first_q <= first;
        acc     <= (first_q ? bias_q : acc) + prod;
    end
endmodule