`timescale 1ns/1ps
// One inference reservation, one result snapshot, one command reply descriptor.
// Accepted results are lossless: launch_ready prevents another frame overwriting them.
module uart_monitor #(parameter CLKS_PER_BIT=868, parameter CLK_MHZ=100,
    parameter UPLOAD_TIMEOUT=CLK_MHZ*1000000, parameter UPLOAD_DRAIN=CLK_MHZ*100000,
    parameter UPLOAD_ENABLE=1)(
    input wire clk, input wire rst, input wire rx, output wire tx,
    input wire pc_mode, input wire mode_pending, input wire system_busy,
    input wire cnn_start, input wire sequence_mode, input wire frame_done,
    input wire [3:0] image_slot, input wire closed, input wire [1:0] warning_state,
    input wire signed [31:0] logit0, logit1, input wire [19:0] latency,
    output reg [3:0] pc_slot, output reg run_pending,
    output reg external_image,
    input wire [9:0] image_read_addr,
    output wire [7:0] image_read_data,
    output wire launch_ready, output wire quiescent
);
    wire [7:0] rx_data;
    wire rx_valid, rx_error, command_valid;
    wire [2:0] command_kind;
    wire [3:0] command_slot;
    wire [15:0] command_id;
    reg load_begin, image_consume;
    wire image_active, image_valid, image_finished;
    wire [1:0] image_error;
    reg [15:0] upload_id, result_id, reply_id, fmt_id, last_id;
    reg last_id_valid;
    uart_image_rx #(.TIMEOUT_CYCLES(UPLOAD_TIMEOUT),.DRAIN_CYCLES(UPLOAD_DRAIN)) u_image (
        .clk(clk),.rst(rst),.begin_load(load_begin),.consume(image_consume || !pc_mode),
        .data(rx_data),.valid(rx_valid),.framing_error(rx_error),
        .read_addr(image_read_addr),.read_data(image_read_data),
        .active(image_active),.frame_valid(image_valid),.finished(image_finished),.error_code(image_error));
    uart_rx #(.CLKS_PER_BIT(CLKS_PER_BIT)) u_rx (
        .clk(clk),.rst(rst),.rx(rx),.data(rx_data),.valid(rx_valid),.framing_error(rx_error));
    uart_command u_command (.clk(clk),.rst(rst || image_active || load_begin),.data(rx_data),.valid(rx_valid),
        .framing_error(rx_error),.command_valid(command_valid),.kind(command_kind),.slot(command_slot),.frame_id(command_id));

    reg transaction, result_pending, result_active, reply_pending, overrun;
    reg [3:0] reply_code, reply_slot;
    reg [1:0] source_q;
    reg [3:0] slot_q;
    reg closed_q;
    reg [1:0] warning_q;
    reg signed [31:0] l0_q,l1_q;
    reg [31:0] cycles_q,us_q;
    reg division_busy;
    reg [19:0] dividend, quotient;
    reg [7:0] remainder;
    reg [4:0] division_bit;
    wire [8:0] shifted_remainder = {remainder,dividend[19]};
    wire subtract_divisor = shifted_remainder >= CLK_MHZ;
    wire [8:0] remainder_next = subtract_divisor ? shifted_remainder-CLK_MHZ : shifted_remainder;
    wire [19:0] quotient_next = {quotient[18:0],subtract_divisor};
    reg fmt_start;
    reg [3:0] fmt_message, fmt_slot;
    wire fmt_ready, fmt_done;
    wire transport_idle = fmt_ready && !fmt_start && !result_pending && !result_active && !reply_pending && !overrun;
    assign quiescent = transport_idle && !image_active && !load_begin && !image_finished && !transaction && !system_busy && !run_pending && !frame_done && !command_valid;
    assign launch_ready = run_pending || (transport_idle && !image_active && !load_begin && !image_finished && !transaction && !mode_pending && !command_valid && !frame_done);
    uart_ascii_tx #(.CLKS_PER_BIT(CLKS_PER_BIT)) u_output (
        .clk(clk),.rst(rst),.start(fmt_start),.message(fmt_message),.slot(fmt_message==0 ? slot_q : fmt_slot),
        .source(source_q),.closed(closed_q),.warning_state(warning_q),
        .logit0(l0_q),.logit1(l1_q),.cycles(cycles_q),.microseconds(us_q),
        .frame_id(fmt_id),
        .ready(fmt_ready),.done(fmt_done),.tx(tx));

    always @(posedge clk) begin
        if (rst) begin
            pc_slot<=0; run_pending<=0; transaction<=0; result_pending<=0; result_active<=0;
            reply_pending<=0; overrun<=0; fmt_start<=0; fmt_message<=0; fmt_slot<=0;
            source_q<=0; slot_q<=0; closed_q<=0; warning_q<=0;
            l0_q<=0; l1_q<=0; cycles_q<=0; us_q<=0; reply_code<=0; reply_slot<=0;
            division_busy<=0; dividend<=0; quotient<=0; remainder<=0; division_bit<=0;
            load_begin<=0; image_consume<=0; external_image<=0;
            upload_id<=0; result_id<=0; reply_id<=0; fmt_id<=0; last_id<=0; last_id_valid<=0;
        end else begin
            fmt_start<=0;
            load_begin<=0; image_consume<=0;
            if (image_finished) begin
                transaction<=0; reply_pending<=1; reply_id<=upload_id;
                case (image_error)
                    0: reply_code<=11;
                    1: reply_code<=12;
                    2: reply_code<=8;
                    default: reply_code<=13;
                endcase
            end
            if (cnn_start) begin
                run_pending<=0; transaction<=1;
                source_q<=pc_mode ? (external_image ? 2'd3 : 2'd1) : sequence_mode ? 2'd2 : 2'd0;
            end
            if (frame_done) begin
                slot_q<=image_slot; closed_q<=closed; warning_q<=warning_state;
                l0_q<=logit0; l1_q<=logit1; cycles_q<={12'd0,latency};
                // Twenty small restoring-division steps avoid a 20-bit combinational
                // divide on the frame snapshot path. This does not change CNN latency.
                dividend<=latency; quotient<=0; remainder<=0; division_bit<=0; division_busy<=1;
            end else if (division_busy) begin
                dividend<={dividend[18:0],1'b0}; quotient<=quotient_next; remainder<=remainder_next[7:0];
                if (division_bit==19) begin
                    us_q<={12'd0,quotient_next}; division_busy<=0; result_pending<=1;
                end else division_bit<=division_bit+1;
            end
            if (fmt_done && result_active) begin result_active<=0; transaction<=0; end

            if (command_valid) begin
                if (reply_pending || fmt_start) overrun<=1;
                else begin
                    reply_pending<=1; reply_slot<=command_slot;
                    if (command_kind>=2 && command_kind<=5) begin
                        case (command_kind)
                            2: reply_code<=5;
                            3: reply_code<=6;
                            4: reply_code<=7;
                            default: reply_code<=8;
                        endcase
                    end else if (!pc_mode) reply_code<=3;
                    else if (transaction || system_busy || run_pending || !transport_idle || mode_pending) reply_code<=4;
                    else if (command_kind==0) begin pc_slot<=command_slot; reply_code<=1; end
                    else if (command_kind==6) begin
                        if (!UPLOAD_ENABLE) reply_code<=3;
                        else if (last_id_valid && command_id==last_id) reply_code<=15;
                        else begin
                            transaction<=1; load_begin<=1; upload_id<=command_id;
                            reply_id<=command_id; reply_code<=10;
                        end
                    end else if (command_kind==7) begin
                        if (!image_valid) reply_code<=14;
                        else if (command_id!=upload_id) reply_code<=15;
                        else begin
                            transaction<=1; run_pending<=1; reply_code<=2;
                            external_image<=1; result_id<=upload_id; image_consume<=1;
                            pc_slot<=0;
                            last_id<=upload_id; last_id_valid<=1;
                        end
                    end else begin transaction<=1; run_pending<=1; reply_code<=2; external_image<=0; end
                end
            end
            // A RUN acknowledgement must precede its RESULT, even for a zero-latency stub.
            if (fmt_ready && !fmt_start) begin
                if (reply_pending && reply_code==2) begin
                    fmt_message<=reply_code; fmt_slot<=reply_slot; fmt_id<=reply_id; fmt_start<=1; reply_pending<=0;
                end else if (result_pending) begin
                    fmt_message<=0; fmt_id<=result_id; fmt_start<=1; result_pending<=0; result_active<=1;
                end else if (reply_pending) begin
                    fmt_message<=reply_code; fmt_slot<=reply_slot; fmt_id<=reply_id; fmt_start<=1; reply_pending<=0;
                end else if (overrun) begin fmt_message<=9; fmt_start<=1; overrun<=0; end
            end
        end
    end
endmodule
