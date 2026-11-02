`timescale 1ns/1ps
// 8N1 receiver. One system clock; sample each bit at its center.
module uart_rx #(parameter CLKS_PER_BIT = 868)(
    input wire clk, input wire rst, input wire rx,
    output reg [7:0] data, output reg valid, output reg framing_error
);
    (* ASYNC_REG = "TRUE" *) reg rx_meta, rx_sync;
    reg [1:0] state;
    reg [31:0] count;
    reg [2:0] bit_index;
    reg [7:0] shift;
    always @(posedge clk) begin
        if (rst) begin rx_meta <= 1'b1; rx_sync <= 1'b1; end
        else begin rx_meta <= rx; rx_sync <= rx_meta; end
    end
    always @(posedge clk) begin
        if (rst) begin
            state <= 0; count <= 0; bit_index <= 0; shift <= 0;
            data <= 0; valid <= 0; framing_error <= 0;
        end else begin
            valid <= 0; framing_error <= 0;
            case (state)
                0: if (!rx_sync) begin count <= 0; state <= 1; end
                1: if (count == CLKS_PER_BIT/2-1) begin
                    count <= 0;
                    if (!rx_sync) begin bit_index <= 0; state <= 2; end
                    else state <= 0;
                end else count <= count + 1;
                2: if (count == CLKS_PER_BIT-1) begin
                    count <= 0; shift[bit_index] <= rx_sync;
                    if (bit_index == 7) state <= 3;
                    else bit_index <= bit_index + 1;
                end else count <= count + 1;
                3: if (count == CLKS_PER_BIT-1) begin
                    count <= 0; state <= 0;
                    if (rx_sync) begin data <= shift; valid <= 1; end
                    else framing_error <= 1;
                end else count <= count + 1;
            endcase
        end
    end
endmodule
