`timescale 1ns / 1ps
//==============================================================================
// maxpool2x2_pipe : 2x2 max pool split in two stages for 150 MHz
//   clock n   : p0..p3 valid
//   clock n+1 : m01 = max(p0,p1), m23 = max(p2,p3)   (registers)
//   clock n+1 : max_val = max(m01,m23)               (combinational, feeds a register)
// Inputs are unsigned (post ReLU/requant, 0..127).
//==============================================================================
module maxpool2x2_pipe (
    input        clk,
    input  [7:0] p0, p1, p2, p3,
    output [7:0] max_val
);
    reg [7:0] m01, m23;
    always @(posedge clk) begin
        m01 <= (p0 > p1) ? p0 : p1;
        m23 <= (p2 > p3) ? p2 : p3;
    end
    assign max_val = (m01 > m23) ? m01 : m23;
endmodule