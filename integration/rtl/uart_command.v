`timescale 1ns/1ps
// LF/CRLF command parser. kind: SLOT=0 RUN=1 CMD=2 RANGE=3 OVERFLOW=4 FRAME=5.
module uart_command(
    input wire clk, input wire rst, input wire [7:0] data,
    input wire valid, input wire framing_error,
    output reg command_valid, output reg [2:0] kind, output reg [3:0] slot,
    output reg [15:0] frame_id
);
    reg [7:0] line [0:31];
    reg [5:0] length;
    reg discard, trailing_cr;
    reg [2:0] reason;
    reg [7:0] number;
    integer j, offset;
    reg hex_ok;
    reg [15:0] parsed_id;
    function [4:0] hex_digit;
        input [7:0] ch;
        begin
            if (ch >= "0" && ch <= "9") hex_digit=ch-"0";
            else if (ch >= "a" && ch <= "f") hex_digit=ch-"a"+10;
            else if (ch >= "A" && ch <= "F") hex_digit=ch-"A"+10;
            else hex_digit=31;
        end
    endfunction
    always @(posedge clk) begin
        if (rst) begin
            length <= 0; discard <= 0; trailing_cr <= 0; reason <= 2;
            command_valid <= 0; kind <= 2; slot <= 0; frame_id <= 0;
        end else begin
            command_valid <= 0;
            if (framing_error) begin discard <= 1; reason <= 5; end
            else if (valid) begin
                if (data == 8'h0a) begin
                    if (discard) begin command_valid <= 1; kind <= reason; end
                    else if (length != 0) begin
                        command_valid <= 1; kind <= 2;
                        if ((length == 9 && {line[0],line[1],line[2],line[3],line[4]} == "LOAD ") ||
                            (length == 14 && {line[0],line[1],line[2],line[3],line[4],line[5],line[6],line[7],line[8],line[9]} == "RUN_FRAME ")) begin
                            offset = (length == 9) ? 5 : 10;
                            hex_ok=1; parsed_id=0;
                            for (j=0;j<4;j=j+1) begin
                                if (hex_digit(line[offset+j]) > 15) hex_ok=0;
                                parsed_id=(parsed_id << 4) | hex_digit(line[offset+j]);
                            end
                            if (hex_ok) begin kind <= (length == 9) ? 6 : 7; frame_id<=parsed_id; end
                        end else if (length == 3 && line[0] == "R" && line[1] == "U" && line[2] == "N") kind <= 1;
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
