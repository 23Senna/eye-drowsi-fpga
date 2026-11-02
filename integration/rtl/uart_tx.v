`timescale 1ns/1ps
// Ready/valid byte interface, LSB first, one stop bit, idle high.
module uart_tx #(parameter CLKS_PER_BIT = 868)(
    input wire clk, input wire rst, input wire [7:0] data,
    input wire valid, output wire ready, output wire tx
);
    reg busy;
    reg [9:0] shift;
    reg [3:0] bit_index;
    reg [31:0] count;
    assign ready = !busy;
    assign tx = busy ? shift[0] : 1'b1;
    always @(posedge clk) begin
        if (rst) begin busy <= 0; shift <= 10'h3ff; bit_index <= 0; count <= 0; end
        else if (!busy) begin
            if (valid) begin
                shift <= {1'b1, data, 1'b0}; busy <= 1;
                bit_index <= 0; count <= 0;
            end
        end else if (count == CLKS_PER_BIT-1) begin
            count <= 0;
            if (bit_index == 9) busy <= 0;
            else begin shift <= {1'b1, shift[9:1]}; bit_index <= bit_index + 1; end
        end else count <= count + 1;
    end
endmodule
