`timescale 1ns / 1ps
//==============================================================================
// mac_sel_150 : picks the MAC implementation at elaboration time
//   USE_DSP = 1 -> mac_pipe_150      (DSP48, fully pipelined)
//   USE_DSP = 0 -> mac_pipe_lut_150  (LUT fabric, 2-stage multiplier)
// Same ports, same latency (acc valid 3 clocks after the operands) in both cases.
//==============================================================================
module mac_sel_150 #(
    parameter USE_DSP = 1
)(
    input                  clk,
    input      [7:0]       a,
    input  signed [7:0]    w,
    input  signed [31:0]   bias,
    input                  first,
    output signed [31:0]   acc
);
    generate
        if (USE_DSP) begin : g_dsp
            mac_pipe_150 u_mac (
                .clk(clk), .a(a), .w(w), .bias(bias), .first(first), .acc(acc)
            );
        end else begin : g_lut
            mac_pipe_lut_150 u_mac (
                .clk(clk), .a(a), .w(w), .bias(bias), .first(first), .acc(acc)
            );
        end
    endgenerate
endmodule