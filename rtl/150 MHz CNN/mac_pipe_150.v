`timescale 1ns / 1ps
//==============================================================================
// mac_pipe_150 : fully pipelined multiply-accumulate for 150 MHz (DSP48 version)
//
//   cycle k   : a (uint8), w (int8), bias (int32), first presented together
//   cycle k+1 : a_q, w_q                     (DSP48 AREG / BREG)
//   cycle k+2 : prod = a_q * w_q             (DSP48 MREG)
//   cycle k+3 : acc  = (first ? bias : acc) + prod   (DSP48 PREG, acc includes this tap)
//
// Compared with mac_pipe (100 MHz): +1 input register stage, so the operands no
// longer have to travel from fabric flip-flops through the multiplier in one clock.
// "bias" is only used while a layer is running; it is static during that time
// (loaded once at layer start), so a single register stage (bias_q) is enough.
//==============================================================================
(* use_dsp = "yes" *)
module mac_pipe_150 (
    input                    clk,
    input      [7:0]         a,
    input  signed [7:0]      w,
    input  signed [31:0]     bias,
    input                    first,
    output reg signed [31:0] acc
);
    reg signed [8:0]  a_q;
    reg signed [7:0]  w_q;
    (* use_dsp48 = "yes" *) reg signed [16:0] prod;
    reg signed [31:0] bias_q;
    reg               first_q1, first_q2;

    always @(posedge clk) begin
        a_q      <= {1'b0, a};
        w_q      <= w;
        bias_q   <= bias;
        first_q1 <= first;
        first_q2 <= first_q1;
        prod     <= a_q * w_q;
        acc      <= (first_q2 ? bias_q : acc) + prod;
    end
endmodule