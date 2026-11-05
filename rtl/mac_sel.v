`timescale 1ns / 1ps
//==============================================================================
// mac_sel : picks the MAC implementation at elaboration time
//   USE_DSP = 1 -> mac_pipe      (multiplier + accumulate in a DSP48)
//   USE_DSP = 0 -> mac_pipe_lut  (multiplier + accumulate in LUT fabric)
// Same ports, same function, same latency (prod at k+1, acc at k+2) in both cases.
//==============================================================================
module mac_sel #(
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
            mac_pipe u_mac (
                .clk(clk), .a(a), .w(w), .bias(bias), .first(first), .acc(acc)
            );
        end else begin : g_lut
            mac_pipe_lut u_mac (
                .clk(clk), .a(a), .w(w), .bias(bias), .first(first), .acc(acc)
            );
        end
    endgenerate
endmodule