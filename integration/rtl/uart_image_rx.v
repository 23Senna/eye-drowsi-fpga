`timescale 1ns/1ps
// Fixed-size binary frame receiver. CRC-16/CCITT-FALSE, high byte first.
// Failed/incomplete frames are never valid. DRAIN requires a quiet interval
// after timeout/framing errors so payload tails cannot become ASCII commands.
module uart_image_rx #(
    parameter TIMEOUT_CYCLES = 100000000,
    parameter DRAIN_CYCLES = 10000000
) (
    input wire clk, rst, begin_load, consume,
    input wire [7:0] data,
    input wire valid, framing_error,
    input wire [9:0] read_addr,
    output reg [7:0] read_data,
    output wire active,
    output reg frame_valid,
    output reg finished,
    output reg [1:0] error_code // 0 success, 1 CRC, 2 framing, 3 timeout
);
    localparam IDLE=0, RECEIVE=1, DRAIN=2;
    reg [1:0] state;
    reg [9:0] count;
    reg [31:0] timer;
    reg [15:0] crc;
    reg [7:0] crc_high;
    reg [7:0] pixels [0:575];
    function [15:0] crc_byte;
        input [15:0] previous;
        input [7:0] value;
        reg [15:0] c;
        integer i;
        begin
            c = previous ^ {value,8'b0};
            for (i=0;i<8;i=i+1) c = c[15] ? (c << 1) ^ 16'h1021 : c << 1;
            crc_byte = c;
        end
    endfunction
    assign active = state != IDLE;
    always @(posedge clk) read_data <= pixels[read_addr];
    always @(posedge clk) begin
        if (rst) begin
            state<=IDLE; count<=0; timer<=0; crc<=16'hffff;
            crc_high<=0; frame_valid<=0; finished<=0; error_code<=0;
        end else begin
            finished<=0;
            if (consume) frame_valid<=0;
            case (state)
                IDLE: if (begin_load) begin
                    state<=RECEIVE; count<=0; timer<=0; crc<=16'hffff;
                    frame_valid<=0; error_code<=0;
                end
                RECEIVE: begin
                    if (framing_error || (!valid && timer == TIMEOUT_CYCLES-1)) begin
                        frame_valid<=0; error_code<=framing_error ? 2 : 3;
                        state<=DRAIN; timer<=0;
                    end else if (valid) begin
                        timer<=0;
                        if (count < 576) begin pixels[count]<=data; crc<=crc_byte(crc,data); end
                        else if (count == 576) crc_high<=data;
                        else begin
                            frame_valid<=({crc_high,data} == crc);
                            error_code<=({crc_high,data} == crc) ? 0 : 1;
                            finished<=1; state<=IDLE;
                        end
                        count<=count+1;
                    end else timer<=timer+1;
                end
                DRAIN: begin
                    if (valid || framing_error) timer<=0;
                    else if (timer == DRAIN_CYCLES-1) begin
                        state<=IDLE; finished<=1; timer<=0;
                    end else timer<=timer+1;
                end
                default: state<=IDLE;
            endcase
        end
    end
endmodule
