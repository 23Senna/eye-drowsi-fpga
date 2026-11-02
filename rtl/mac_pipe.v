`timescale 1ns / 1ps
//==============================================================================
// mac_pipe : pipelined multiply-accumulate, 1 tap per clock, for 100 MHz
//
//   cycle k   : a (uint8), w (int8), bias (int32), first  presented together
//   cycle k+1 : prod = a * w                       (DSP48, input regs are upstream)
//   cycle k+2 : acc  = (first ? bias : acc) + prod (acc includes this tap)
//
// first = 1 on the first tap of an output value: the accumulator is loaded with
// the bias instead of the old acc (so no separate clear / bias-add stage).
// No reset on purpose (better timing, DSP-friendly): acc is only meaningful
// on the cycle the caller's tag says "last tap" came through.
//==============================================================================
module mac_pipe (
    input                    clk,
    input      [7:0]         a,
    input  signed [7:0]      w,
    input  signed [31:0]     bias,
    input                    first,
    output reg signed [31:0] acc
);
    (* use_dsp48 = "yes" *) reg signed [16:0] prod;
    reg signed [31:0] bias_q;
    reg               first_q;

    always @(posedge clk) begin
        prod    <= $signed({1'b0, a}) * w;
        bias_q  <= bias;
        first_q <= first;
        acc     <= (first_q ? bias_q : acc) + prod;
    end
endmodule