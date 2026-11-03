`timescale 1ns / 1ps
//==============================================================================
// cnn_top : structural top
//
//   rom_weights --> conv1_layer --> conv2_layer --> fc_layer
//                    (mac_pipe, relu_requant, maxpool2x2 inside each conv layer)
//
// Top only owns: image loader, the three buffers (img / a1 / a2),
//                the ROM instance, and a small sequencing FSM.
//==============================================================================
module cnn_top #(parameter EXTERNAL_INPUT = 0) (
    input clk,
    input rst,
    input start,
    input [13:0] img_base_addr,
    input external_image,
    output wire [9:0] external_addr,
    input [7:0] external_data,
    output reg done,
    output reg prediction,      // 0: Closed, 1: Open
    output signed [31:0] logit0,
    output signed [31:0] logit1
);

    // ---------------- Buffers
    reg [7:0] img_mem [0:575];  // 24x24 uint8 input image
    reg [7:0] a1_mem  [0:483];  // 4x11x11 pooled feature map 1
    reg [7:0] a2_mem  [0:127];  // 8x4x4  pooled feature map 2

    // ---------------- Top FSM
    localparam ST_IDLE     = 4'd0,
               ST_LOAD_REQ = 4'd1,
               ST_LOAD_RD  = 4'd2,
               ST_L1_GO    = 4'd3,
               ST_L1_WAIT  = 4'd4,
               ST_L2_GO    = 4'd5,
               ST_L2_WAIT  = 4'd6,
               ST_FC_GO    = 4'd7,
               ST_FC_WAIT  = 4'd8,
               ST_DONE     = 4'd9;

    reg [3:0] state;
    reg [9:0] load_cnt;
    reg external_q;

    // layer handshakes
    wire l1_start = (state == ST_L1_GO);
    wire l2_start = (state == ST_L2_GO);
    wire fc_start = (state == ST_FC_GO);
    wire l1_done, l2_done, fc_done;

    // ---------------- ROM
    wire [5:0]  c1_w_addr;  wire signed [7:0]  c1_w_data;
    wire [1:0]  c1_b_addr;  wire signed [31:0] c1_b_data;
    wire [8:0]  c2_w_addr;  wire signed [7:0]  c2_w_data;
    wire [2:0]  c2_b_addr;  wire signed [31:0] c2_b_data;
    wire [7:0]  fc_w_addr;  wire signed [7:0]  fc_w_data;
    wire        fc_b_addr;  wire signed [31:0] fc_b_data;
    reg  [13:0] rom_img_addr;
    assign external_addr = rom_img_addr[9:0];
    wire [7:0]  rom_img_data;

    rom_weights rom_inst (
        .clk(clk),
        .conv1_w_addr(c1_w_addr), .conv1_w_data(c1_w_data),
        .conv1_b_addr(c1_b_addr), .conv1_b_data(c1_b_data),
        .conv2_w_addr(c2_w_addr), .conv2_w_data(c2_w_data),
        .conv2_b_addr(c2_b_addr), .conv2_b_data(c2_b_data),
        .fc_w_addr(fc_w_addr),    .fc_w_data(fc_w_data),
        .fc_b_addr(fc_b_addr),    .fc_b_data(fc_b_data),
        .img_addr(rom_img_addr),  .img_data(rom_img_data)
    );

    // ---------------- Layer 1
    wire [9:0] l1_img_addr;
    reg  [7:0] l1_img_data;     // sync read: data 1 clock after the address (layer contract)
    wire       a1_we;
    wire [8:0] a1_waddr;
    wire [7:0] a1_wdata;

    conv1_layer u_conv1 (
        .clk(clk), .rst(rst), .start(l1_start), .done(l1_done),
        .img_addr(l1_img_addr), .img_data(l1_img_data),
        .w_addr(c1_w_addr), .w_data(c1_w_data),
        .b_addr(c1_b_addr), .b_data(c1_b_data),
        .a1_we(a1_we), .a1_waddr(a1_waddr), .a1_wdata(a1_wdata)
    );

    // ---------------- Layer 2
    wire [8:0] l2_a1_addr;
    reg  [7:0] l2_a1_data;      // sync read
    wire       a2_we;
    wire [6:0] a2_waddr;
    wire [7:0] a2_wdata;

    conv2_layer u_conv2 (
        .clk(clk), .rst(rst), .start(l2_start), .done(l2_done),
        .a1_addr(l2_a1_addr), .a1_data(l2_a1_data),
        .w_addr(c2_w_addr), .w_data(c2_w_data),
        .b_addr(c2_b_addr), .b_data(c2_b_data),
        .a2_we(a2_we), .a2_waddr(a2_waddr), .a2_wdata(a2_wdata)
    );

    // ---------------- FC
    wire [6:0] fc_a2_addr;
    reg  [7:0] fc_a2_data;      // sync read

    fc_layer u_fc (
        .clk(clk), .rst(rst), .start(fc_start), .done(fc_done),
        .a2_addr(fc_a2_addr), .a2_data(fc_a2_data),
        .w_addr(fc_w_addr), .w_data(fc_w_data),
        .b_addr(fc_b_addr), .b_data(fc_b_data),
        .logit0(logit0), .logit1(logit1)
    );

    // ---------------- Buffer reads (synchronous, like rom_weights: the layers'
    // pipelines expect img/a1/a2 data one clock after the address, together with w_data)
    always @(posedge clk) begin
        l1_img_data <= img_mem[l1_img_addr];
        l2_a1_data  <= a1_mem[l2_a1_addr];
        fc_a2_data  <= a2_mem[fc_a2_addr];
    end

    // ---------------- Buffer writes
    always @(posedge clk) begin
        if (state == ST_LOAD_RD) img_mem[load_cnt] <= external_q ? external_data : rom_img_data;
        if (a1_we)               a1_mem[a1_waddr]  <= a1_wdata;
        if (a2_we)               a2_mem[a2_waddr]  <= a2_wdata;
    end

    // ---------------- Sequencing FSM
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state      <= ST_IDLE;
            done       <= 1'b0;
            prediction <= 1'b0;
            load_cnt   <= 10'd0;
            external_q <= 1'b0;
        end else begin
            case (state)
                ST_IDLE: begin
                    done <= 1'b0;
                    if (start) begin
                        external_q <= EXTERNAL_INPUT ? external_image : 1'b0;
                        load_cnt     <= 10'd0;
                        rom_img_addr <= img_base_addr;
                        state        <= ST_LOAD_REQ;
                    end
                end

                ST_LOAD_REQ: state <= ST_LOAD_RD;

                ST_LOAD_RD: begin
                    if (load_cnt == 575) begin
                        state <= ST_L1_GO;
                    end else begin
                        load_cnt     <= load_cnt + 1;
                        rom_img_addr <= img_base_addr + (load_cnt + 1);
                        state        <= ST_LOAD_REQ;
                    end
                end

                ST_L1_GO:   state <= ST_L1_WAIT;
                ST_L1_WAIT: if (l1_done) state <= ST_L2_GO;

                ST_L2_GO:   state <= ST_L2_WAIT;
                ST_L2_WAIT: if (l2_done) state <= ST_FC_GO;

                ST_FC_GO:   state <= ST_FC_WAIT;
                ST_FC_WAIT: if (fc_done) state <= ST_DONE;

                ST_DONE: begin
                    done       <= 1'b1;
                    prediction <= (logit1 > logit0) ? 1'b1 : 1'b0;
                    if (!start) state <= ST_IDLE;
                end

                default: state <= ST_IDLE;
            endcase
        end
    end

endmodule
