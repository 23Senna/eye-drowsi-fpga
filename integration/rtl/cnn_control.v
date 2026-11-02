// cnn_control.v - layer sequencing for cnn_core (worst-case owner: integration).
// Network (Python quantize_export.py):
//   24x24 -> conv1 1->4 3x3 (22x22) -> act(S1) -> pool 11x11 -> a1 (4x11x11)
//         -> conv2 4->8 3x3 (9x9)   -> act(S2) -> pool 4x4 (floor) -> a2 (8x4x4 = 128) -> FC 128->2
//   act(acc, S) = clip(acc >>> S, 0, 127)
// Conv layers produce outputs in pool order f, py, px, dy, dx (conv pixel (2py+dy, 2px+dx)), taps ci, ky, kx,
// one tap per cycle. Every 4 consecutive conv outputs = one pool window, written to the activation buffer at
//   a1: act_wr_addr = f*121 + py*11 + px          (layer 0)
//   a2: act_wr_addr = 512 + f*16 + py*4 + px      (layer 1, = FC feature order ch*16 + r*4 + c)
// conv2 skips conv row/col 8 (floor pooling drops it). FC: act_rd_addr = 512 + k, w = 324 + c*128 + k.
// Read addresses (img_addr, act_rd_addr, w_addr, b_addr) are combinational from the counters; the memories
// answer one cycle later, so every strobe below is delayed by 1 cycle and lines up with the data:
//   mac_en: acc <= (mac_clr ? b : acc) + x * w      x = layer 0 ? img_data : act_rd_data
//   mac_last: last tap of one output; win_last: last conv output of a pool window -> write max to act_wr_addr
//   layer 2 (FC): on mac_last store logit[fc_class]; argmax_en: register eye_state (valid when done = 1)
module cnn_control #(
    parameter DRAIN = 4             // idle cycles between layers (>= 2: pipeline + buffer write)
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        start,
    output reg         busy,
    output wire        done,
    // memory read addresses
    output wire [9:0]  img_addr,      // row*24 + col; the top level adds the slot bits
    output wire [9:0]  act_rd_addr,   // activation buffer (a1 at 0-483, a2 at 512-639)
    output wire [11:0] w_addr,
    output wire [4:0]  b_addr,
    // datapath strobes (data-aligned)
    output reg  [1:0]  layer,         // 0 conv1, 1 conv2, 2 fc
    output reg         mac_en,
    output reg         mac_clr,
    output reg         mac_last,
    output reg         win_last,
    output reg  [9:0]  act_wr_addr,
    output reg         fc_class,
    output reg         argmax_en
);
    localparam S_IDLE = 3'd0, S_CONV = 3'd1, S_DRAIN = 3'd2, S_FC = 3'd3, S_DONE = 3'd4;
    reg [2:0] state;
    reg       lyr;                    // conv layer being run: 0 conv1, 1 conv2
    reg       fc_seen;                // the current drain follows the FC phase
    reg [2:0] f;
    reg [3:0] py, px;
    reg       dy, dx, c;
    reg [1:0] ci, ky, kx;
    reg [6:0] k;
    reg [3:0] wait_cnt;

    // per-layer loop limits
    wire [2:0] F_LAST  = lyr ? 3'd7 : 3'd3;
    wire [3:0] HP_LAST = lyr ? 4'd3 : 4'd10;
    wire [1:0] CI_LAST = lyr ? 2'd3 : 2'd0;

    wire [4:0] row = {py, 1'b0} + dy + ky;
    wire [4:0] col = {px, 1'b0} + dx + kx;

    assign img_addr    = row * 10'd24 + col;
    assign act_rd_addr = (state == S_FC) ? 10'd512 + k : ci * 10'd121 + row * 10'd11 + col;
    assign w_addr      = (state == S_FC) ? 12'd324 + (c ? 12'd128 : 12'd0) + k
                       : lyr ? 12'd36 + f * 12'd36 + ci * 12'd9 + ky * 12'd3 + kx
                       :       f * 12'd9 + ky * 12'd3 + kx;
    assign b_addr      = (state == S_FC) ? 5'd12 + c : lyr ? 5'd4 + f : {2'b00, f};
    assign done        = (state == S_DONE);

    wire last_tap  = (kx == 2'd2) && (ky == 2'd2) && (ci == CI_LAST);
    wire last_win  = last_tap && dy && dx;
    wire last_conv = last_win && (px == HP_LAST) && (py == HP_LAST) && (f == F_LAST);
    wire [9:0] wr_a1 = f * 10'd121 + py * 10'd11 + px;
    wire [9:0] wr_a2 = 10'd512 + {f, 4'b0000} + {py[1:0], 2'b00} + px;

    // strobes, delayed 1 cycle to line up with the memory data
    always @(posedge clk) begin
        if (rst) begin
            {mac_en, mac_clr, mac_last, win_last, fc_class, argmax_en} <= 6'd0;
            layer <= 2'd0; act_wr_addr <= 10'd0;
        end else begin
            mac_en      <= (state == S_CONV) || (state == S_FC);
            mac_clr     <= (state == S_CONV) ? (kx == 2'd0 && ky == 2'd0 && ci == 2'd0)
                                             : (state == S_FC) && (k == 7'd0);
            mac_last    <= (state == S_CONV) ? last_tap : (state == S_FC) && (k == 7'd127);
            win_last    <= (state == S_CONV) && last_win;
            act_wr_addr <= lyr ? wr_a2 : wr_a1;
            layer       <= (state == S_FC) ? 2'd2 : {1'b0, lyr};
            fc_class    <= c;
            argmax_en   <= (state == S_DRAIN) && fc_seen && (wait_cnt == DRAIN - 2);   // eye valid in S_DONE
        end
    end

    always @(posedge clk) begin
        if (rst) begin
            state <= S_IDLE; busy <= 1'b0; lyr <= 1'b0; fc_seen <= 1'b0;
            {f, py, px, dy, dx, ci, ky, kx, c, k, wait_cnt} <= 0;
        end else case (state)
            S_IDLE: if (start) begin
                busy <= 1'b1; state <= S_CONV; lyr <= 1'b0; fc_seen <= 1'b0;
                {f, py, px, dy, dx, ci, ky, kx, c, k, wait_cnt} <= 0;
            end
            S_CONV: begin
                // innermost first: kx, ky, ci, dx, dy, px, py, f
                kx <= (kx == 2'd2) ? 2'd0 : kx + 2'd1;
                if (kx == 2'd2) begin
                    ky <= (ky == 2'd2) ? 2'd0 : ky + 2'd1;
                    if (ky == 2'd2) begin
                        ci <= (ci == CI_LAST) ? 2'd0 : ci + 2'd1;
                        if (ci == CI_LAST) begin
                            dx <= ~dx;
                            if (dx) begin
                                dy <= ~dy;
                                if (dy) begin
                                    px <= (px == HP_LAST) ? 4'd0 : px + 4'd1;
                                    if (px == HP_LAST) begin
                                        py <= (py == HP_LAST) ? 4'd0 : py + 4'd1;
                                        if (py == HP_LAST) f <= (f == F_LAST) ? 3'd0 : f + 3'd1;
                                    end
                                end
                            end
                        end
                    end
                end
                if (last_conv) begin state <= S_DRAIN; wait_cnt <= 4'd0; end
            end
            S_DRAIN: begin
                wait_cnt <= wait_cnt + 4'd1;
                if (wait_cnt == DRAIN - 1) begin
                    wait_cnt <= 4'd0;
                    if (fc_seen)        state <= S_DONE;
                    else if (!lyr) begin state <= S_CONV; lyr <= 1'b1; end
                    else           begin state <= S_FC; k <= 7'd0; c <= 1'b0; end
                end
            end
            S_FC: begin
                k <= k + 7'd1;            // wraps 127 -> 0
                if (k == 7'd127) begin
                    c <= ~c;
                    if (c) begin state <= S_DRAIN; fc_seen <= 1'b1; end
                end
            end
            S_DONE: begin busy <= 1'b0; state <= S_IDLE; end
            default: state <= S_IDLE;
        endcase
    end
endmodule
