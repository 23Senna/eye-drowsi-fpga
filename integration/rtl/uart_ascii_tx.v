`timescale 1ns/1ps
// Build one complete ASCII record, then serialize it without interleaving.
// Decimal conversion uses 32 shift/add-3 cycles instead of a long divider chain.
// message: RESULT, OK SLOT, OK RUN, MODE, BUSY, CMD, RANGE, OVERFLOW, FRAME, OVERRUN.
module uart_ascii_tx #(parameter CLKS_PER_BIT = 868)(
    input wire clk, input wire rst, input wire start, input wire [3:0] message,
    input wire [3:0] slot, input wire [1:0] source, input wire closed,
    input wire [1:0] warning_state,
    input wire signed [31:0] logit0, logit1,
    input wire [31:0] cycles, microseconds,
    input wire [15:0] frame_id,
    output wire ready, output reg done, output wire tx
);
    localparam IDLE=0, FIELD=1, TEXT=2, CONVERT=3, DIGITS=4, SEND=5, DRAIN=6;
    reg [2:0] state;
    reg [3:0] msg_q, slot_q;
    reg [1:0] source_q, warning_q;
    reg closed_q;
    reg [31:0] l0_q, l1_q, cycles_q, us_q;
    reg [15:0] frame_id_q;
    reg [4:0] field;
    reg [7:0] length, send_index;
    reg [7:0] buffer [0:159];
    reg [127:0] text_q;
    reg [4:0] text_length, text_index;
    reg [31:0] binary;
    reg [39:0] bcd, corrected;
    reg [5:0] bit_count;
    reg [3:0] digit_index;
    reg leading;
    integer i;
    reg [1:0] field_type;
    reg [127:0] field_text;
    reg [4:0] field_length;
    reg [31:0] field_number;
    reg field_signed;

    wire byte_ready;
    wire byte_valid = (state == SEND);
    uart_tx #(.CLKS_PER_BIT(CLKS_PER_BIT)) u_tx (
        .clk(clk), .rst(rst), .data(buffer[send_index]),
        .valid(byte_valid), .ready(byte_ready), .tx(tx));
    assign ready = (state == IDLE);

    always @* begin
        corrected = bcd;
        for (i=0; i<10; i=i+1)
            if (bcd[i*4 +: 4] >= 5) corrected[i*4 +: 4] = bcd[i*4 +: 4] + 4'd3;
    end
    // field_type: text=0, decimal=1, end=2.
    always @* begin
        field_type=2; field_text=0; field_length=0; field_number=0; field_signed=0;
        if (msg_q == 0) begin
            case (field)
                0: begin field_type=0; field_text="RESULT source="; field_length=14; end
                1: begin
                    field_type=0;
                    case (source_q)
                        0: begin field_text="BOARD"; field_length=5; end
                        1: begin field_text="PC"; field_length=2; end
                        2: begin field_text="SEQ"; field_length=3; end
                        default: begin field_text="UPLOAD"; field_length=6; end
                    endcase
                end
                2: begin field_type=0; field_text=" slot="; field_length=6; end
                3: begin field_type=1; field_number={28'd0,slot_q}; end
                4: begin field_type=0; field_text=" class="; field_length=7; end
                5: begin
                    field_type=0;
                    if (closed_q) begin field_text="CLOSED"; field_length=6; end
                    else begin field_text="OPEN"; field_length=4; end
                end
                6: begin field_type=0; field_text=" warning="; field_length=9; end
                7: begin
                    field_type=0;
                    case (warning_q)
                        0: begin field_text="AWAKE"; field_length=5; end
                        1: begin field_text="DROWSY"; field_length=6; end
                        default: begin field_text="MICROSLEEP"; field_length=10; end
                    endcase
                end
                8: begin field_type=0; field_text=" logit0="; field_length=8; end
                9: begin field_type=1; field_number=l0_q; field_signed=1; end
                10: begin field_type=0; field_text=" logit1="; field_length=8; end
                11: begin field_type=1; field_number=l1_q; field_signed=1; end
                12: begin field_type=0; field_text=" cycles="; field_length=8; end
                13: begin field_type=1; field_number=cycles_q; end
                14: begin field_type=0; field_text=" us="; field_length=4; end
                15: begin field_type=1; field_number=us_q; end
                16: begin
                    field_type=0;
                    if (source_q==3) begin field_text=" frame_id="; field_length=10; end
                    else begin field_text=16'h0d0a; field_length=2; end
                end
                17: if (source_q==3) begin field_type=1; field_number={16'd0,frame_id_q}; end
                18: if (source_q==3) begin field_type=0; field_text=16'h0d0a; field_length=2; end
                default: ;
            endcase
        end else if (msg_q == 1) begin
            case (field)
                0: begin field_type=0; field_text="OK SLOT "; field_length=8; end
                1: begin field_type=1; field_number={28'd0,slot_q}; end
                2: begin field_type=0; field_text=16'h0d0a; field_length=2; end
                default: ;
            endcase
        end else if (msg_q == 10 || msg_q == 11) begin
            case (field)
                0: begin
                    field_type=0;
                    if (msg_q==10) begin field_text="READY "; field_length=6; end
                    else begin field_text="OK FRAME "; field_length=9; end
                end
                1: begin field_type=1; field_number={16'd0,frame_id_q}; end
                2: begin field_type=0; field_text=16'h0d0a; field_length=2; end
                default: ;
            endcase
        end else if (field == 0) begin
            field_type=0;
            case (msg_q)
                2: begin field_text={"OK RUN",16'h0d0a}; field_length=8; end
                3: begin field_text={"ERR MODE",16'h0d0a}; field_length=10; end
                4: begin field_text={"ERR BUSY",16'h0d0a}; field_length=10; end
                5: begin field_text={"ERR CMD",16'h0d0a}; field_length=9; end
                6: begin field_text={"ERR RANGE",16'h0d0a}; field_length=11; end
                7: begin field_text={"ERR OVERFLOW",16'h0d0a}; field_length=14; end
                8: begin field_text={"ERR FRAME",16'h0d0a}; field_length=11; end
                12: begin field_text={"ERR CRC",16'h0d0a}; field_length=9; end
                13: begin field_text={"ERR TIMEOUT",16'h0d0a}; field_length=13; end
                14: begin field_text={"ERR NOFRAME",16'h0d0a}; field_length=13; end
                15: begin field_text={"ERR ID",16'h0d0a}; field_length=8; end
                default: begin field_text={"ERR OVERRUN",16'h0d0a}; field_length=13; end
            endcase
        end
    end
    always @(posedge clk) begin
        if (rst) begin state<=IDLE; done<=0; length<=0; send_index<=0; end
        else begin
            done<=0;
            case (state)
                IDLE: if (start) begin
                    msg_q<=message; slot_q<=slot; source_q<=source; closed_q<=closed;
                    warning_q<=warning_state; l0_q<=logit0; l1_q<=logit1;
                    cycles_q<=cycles; us_q<=microseconds;
                    frame_id_q<=frame_id;
                    length<=0; field<=0; state<=FIELD;
                end
                FIELD: case (field_type)
                    0: begin text_q<=field_text; text_length<=field_length; text_index<=0; state<=TEXT; end
                    1: begin
                        binary <= (field_signed && field_number[31]) ? (~field_number + 32'd1) : field_number;
                        bcd<=0; bit_count<=0; leading<=1;
                        if (field_signed && field_number[31]) begin buffer[length]<=8'h2d; length<=length+1; end
                        state<=CONVERT;
                    end
                    default: begin send_index<=0; state<=SEND; end
                endcase
                TEXT: begin
                    buffer[length]<=text_q[(text_length-1-text_index)*8 +: 8]; length<=length+1;
                    if (text_index == text_length-1) begin field<=field+1; state<=FIELD; end
                    else text_index<=text_index+1;
                end
                CONVERT: begin
                    bcd<={corrected[38:0],binary[31]}; binary<={binary[30:0],1'b0};
                    if (bit_count==31) begin digit_index<=9; state<=DIGITS; end
                    else bit_count<=bit_count+1;
                end
                DIGITS: begin
                    if (!leading || bcd[digit_index*4 +: 4]!=0 || digit_index==0) begin
                        buffer[length]<=8'h30+{4'd0,bcd[digit_index*4 +: 4]};
                        length<=length+1; leading<=0;
                    end
                    if (digit_index==0) begin field<=field+1; state<=FIELD; end
                    else digit_index<=digit_index-1;
                end
                SEND: if (byte_ready) begin
                    if (send_index==length-1) state<=DRAIN;
                    else send_index<=send_index+1;
                end
                DRAIN: if (byte_ready) begin state<=IDLE; done<=1; end
                default: state<=IDLE;
            endcase
        end
    end
endmodule
