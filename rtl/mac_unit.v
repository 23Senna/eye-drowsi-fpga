`timescale 1ns / 1ps
//==============================================================================
// mac_unit : sequential multiply-accumulate, 1 product per clock
//   acc <= acc + a * w      (a = uint8, w = int8, acc = int32)
// acc_next is the combinational value acc + a*w (used by FC to latch the
// final sum in the same cycle as the last product).
// clr has priority over en.
//==============================================================================
module mac_unit (
    input                    clk,
    input                    rst,       // async, active high
    input                    clr,       // acc <= 0
    input                    en,        // acc <= acc + a*w
    input      [7:0]         a,         // unsigned activation / pixel
    input  signed [7:0]      w,         // signed weight
    output reg signed [31:0] acc,
    output signed [31:0]     acc_next
);
    wire signed [31:0] prod = $signed({1'b0, a}) * w;
    assign acc_next = acc + prod;

    always @(posedge clk or posedge rst) begin
        if (rst)      acc <= 32'sd0;
        else if (clr) acc <= 32'sd0;
        else if (en)  acc <= acc_next;
    end
endmodule
