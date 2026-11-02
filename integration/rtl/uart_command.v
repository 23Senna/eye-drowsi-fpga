`timescale 1ns/1ps
// LF/CRLF command parser. kind: SLOT=0 RUN=1 CMD=2 RANGE=3 OVERFLOW=4 FRAME=5.
module uart_command(
    input wire clk, input wire rst, input wire [7:0] data,
    input wire valid, input wire framing_error,
    output reg command_valid, output reg [2:0] kind, output reg [3:0] slot
);
    reg [7:0] line [0:31];
    reg [5:0] length;
    reg discard, trailing_cr;
    reg [2:0] reason;
    reg [7:0] number;
    always @(posedge clk) begin
        if (rst) begin
            length <= 0; discard <= 0; trailing_cr <= 0; reason <= 2;
            command_valid <= 0; kind <= 2; slot <= 0;
        end else begin
            command_valid <= 0;
            if (framing_error) begin discard <= 1; reason <= 5; end
            else if (valid) begin
                if (data == 8'h0a) begin
                    if (discard) begin command_valid <= 1; kind <= reason; end
                    else if (length != 0) begin
                        command_valid <= 1; kind <= 2;
                        if (length == 3 && line[0] == "R" && line[1] == "U" && line[2] == "N") kind <= 1;
                        else if (length >= 5 && line[0] == "S" && line[1] == "L" && line[2] == "O" && line[3] == "T" && line[4] == " ") begin
                            kind <= 3;
                            if ((length == 6 || length == 7) && line[5] >= "0" && line[5] <= "9") begin
                                number = line[5] - "0";
                                if (length == 7) number = number*10 + line[6] - "0";
                                if ((length == 6 || (line[6] >= "0" && line[6] <= "9")) && number < 16) begin
                                    kind <= 0; slot <= number[3:0];
                                end
                            end
                        end
                    end
                    length <= 0; discard <= 0; trailing_cr <= 0;
                end else if (!discard) begin
                    if (trailing_cr) begin discard <= 1; reason <= 2; end
                    else if (data == 8'h0d) trailing_cr <= 1;
                    else if (length == 32) begin discard <= 1; reason <= 4; end
                    else begin line[length[4:0]] <= data; length <= length + 1; end
                end
            end
        end
    end
endmodule
