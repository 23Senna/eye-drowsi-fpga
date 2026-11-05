`timescale 1ns / 1ps
//==============================================================================
// mac_pipe_lut_150 : same function / same latency as mac_pipe_150, built in LUTs.
//
//   cycle k   : a (uint8), w (int8), bias (int32), first presented together
//   cycle k+1 : pp_lo = a * w[3:0]  (unsigned 8x4)   pp_hi = a * w[7:4] (signed 8x4)
//   cycle k+2 : prod  = (pp_hi << 4) + pp_lo         (= a * w)
//   cycle k+3 : acc   = (first ? bias : acc) + prod
//
// A single 8x8 multiplier in LUT fabric is ~5-7 ns, too slow for 150 MHz, so the
// multiplier is split in two 8x4 halves (w = 16*w_hi + w_lo, w_hi signed, w_lo
// unsigned) with a register in between.
//==============================================================================
(* use_dsp = "no" *)
module mac_pipe_lut_150 (
    input                    clk,
    input      [7:0]         a,
    input  signed [7:0]      w,
    input  signed [31:0]     bias,
    input                    first,
    output reg signed [31:0] acc
);
    wire signed [3:0] w_hi = w[7:4];

    (* use_dsp48 = "no" *) reg        [11:0] pp_lo;
    (* use_dsp48 = "no" *) reg signed [12:0] pp_hi;
    (* use_dsp48 = "no" *) reg signed [16:0] prod;
    reg signed [31:0] bias_q;
    reg               first_q1, first_q2;

    always @(posedge clk) begin
        pp_lo    <= a * w[3:0];
        pp_hi    <= $signed({1'b0, a}) * w_hi;
        prod     <= (pp_hi <<< 4) + $signed({5'b00000, pp_lo});
        bias_q   <= bias;
        first_q1 <= first;
        first_q2 <= first_q1;
        acc      <= (first_q2 ? bias_q : acc) + prod;
    end
endmodule