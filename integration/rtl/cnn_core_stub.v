// cnn_core_stub.v - stand-in for cnn_core until the real core lands.
// Same ports as cnn_core (INTERFACE.md) plus the stub-only input `slot` for the golden-logit lookup.
// On start: busy for LATENCY cycles (default = cnn_top latency), reads the 576 pixels of the slot
// (exercises the image ROM path, sum kept in pix_sum for tb_top), done is a 1-cycle pulse LATENCY
// cycles after the start cycle. logit0/1 = Python golden logits (stub_logits.mem), eye_state = logit0 >= logit1
// (FC class 0 = closed, argmax tie -> class 0).
module cnn_core_stub #(
    parameter LATENCY    = 75826,         // = cnn_top latency, must be > 578
    parameter LOGIT_FILE = "stub_logits.mem"
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        start,
    input  wire [3:0]  slot,              // stub only
    output reg         busy,
    output wire        done,
    output reg         eye_state,
    output reg  signed [31:0] logit0,
    output reg  signed [31:0] logit1,
    output wire [13:0] img_addr,
    input  wire [7:0]  img_data,
    output wire [11:0] w_addr,
    input  wire [7:0]  w_data,
    output wire [4:0]  b_addr,
    input  wire [31:0] b_data
);
    reg [47:0] golden [0:15];
    initial $readmemh(LOGIT_FILE, golden);

    reg [19:0] cnt;
    reg [3:0]  slot_l;
    reg [19:0] pix_sum;
    wire [19:0] pix_idx = cnt - 20'd1;
    wire [47:0] g = golden[slot_l];

    assign done     = busy && (cnt == LATENCY);
    assign img_addr = {4'b0000, pix_idx[9:0]};   // top level adds the slot
    assign w_addr   = 12'd0;
    assign b_addr   = 5'd0;

    always @(posedge clk) begin
        if (rst) begin
            busy <= 1'b0; cnt <= 20'd0; slot_l <= 4'd0; pix_sum <= 20'd0;
            eye_state <= 1'b0; logit0 <= 32'sd0; logit1 <= 32'sd0;
        end else if (!busy) begin
            if (start) begin
                busy <= 1'b1; cnt <= 20'd1; slot_l <= slot; pix_sum <= 20'd0;
            end
        end else begin
            cnt <= cnt + 20'd1;
            if (cnt >= 20'd2 && cnt <= 20'd577) pix_sum <= pix_sum + img_data;
            if (cnt == LATENCY - 1) begin
                logit0    <= {{8{g[47]}}, g[47:24]};
                logit1    <= {{8{g[23]}}, g[23:0]};
                eye_state <= ($signed(g[47:24]) >= $signed(g[23:0]));
            end
            if (done) busy <= 1'b0;
        end
    end
endmodule
