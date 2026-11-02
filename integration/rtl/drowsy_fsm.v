// drowsy_fsm.v - system FSM + drowsiness rules (contract: python/drowsy_ref.py).
// IDLE -> START_CNN (cnn_start pulse) -> WAIT_DONE (latency count) -> UPDATE (one drowsy_ref step) -> SHOW -> IDLE
// Manual mode: one inference per start_pulse on slot_sw.
// Sequence mode: every STEP_TICKS cycles the next slot of SEQ_FILE (SEQ_LEN entries, wraps) is classified;
//   seq_slow: every SLOW_TICKS cycles instead (demo, 1 s); seq_step: one frame per start_pulse (btnC);
//   seq_scan: slots 0, 1, ..., 15, 0, ... instead of the SEQ_FILE script (restarts at 0 when switched on).
// Toggling seq_mode clears the drowsiness state, the sequence pointer and have_result.
// Low-confidence hold (low_conf_en): |logit0 - logit1| < CONF_MARGIN -> eye_eff = previous eye_eff.
module drowsy_fsm #(
    parameter STEP_TICKS  = 10000000,     // 100 ms @ 100 MHz
    parameter SLOW_TICKS  = 100000000,    // 1 s @ 100 MHz (seq_slow)
    parameter SEQ_LEN     = 64,
    parameter SEQ_FILE    = "seq.mem",
    parameter W           = 32,           // window (count is 6 bit -> W <= 63)
    parameter DROWSY_ON   = 13,
    parameter DROWSY_OFF  = 6,
    parameter SLEEP_RUN   = 8,
    parameter WAKE_RUN    = 10,
    parameter CLK_MHZ     = 100,          // system clock, for the microsecond latency counter
    parameter CONF_MARGIN = 1024          // logit units (TBD with the Python owner)
) (
    input  wire        clk,
    input  wire        rst,
    // from input_control
    input  wire        start_pulse,
    input  wire [3:0]  slot_sw,
    input  wire        seq_mode,
    input  wire        seq_slow,
    input  wire        seq_step,
    input  wire        seq_scan,
    input  wire        low_conf_en,
    // cnn_core
    output wire        cnn_start,
    input  wire        cnn_done,
    input  wire        cnn_eye,
    input  wire signed [31:0] cnn_logit0,
    input  wire signed [31:0] cnn_logit1,
    // results
    output reg  [3:0]  img_slot,
    output wire        busy,
    output reg         frame_done,      // 1-cycle pulse in SHOW
    output reg         have_result,
    output reg         eye_state,       // raw CNN class of the last frame
    output reg  [1:0]  drowsy_state,    // 0 AWAKE, 1 DROWSY, 2 MICROSLEEP
    output reg  [5:0]  closed_count,
    output reg  [5:0]  closed_run,
    output reg  [5:0]  open_run,
    output wire [6:0]  perclos,         // percent, (count * 25) >> 3 for W = 32
    output reg  [19:0] latency,         // cycles from cnn_start to cnn_done (saturates)
    output reg  [15:0] latency_us       // same in microseconds, 4-digit BCD (for the 7-segment)
);
    localparam S_IDLE = 3'd0, S_START = 3'd1, S_WAIT = 3'd2, S_UPDATE = 3'd3, S_SHOW = 3'd4;
    localparam ST_AWAKE = 2'd0, ST_DROWSY = 2'd1, ST_SLEEP = 2'd2;
    localparam [5:0] RUN_MAX = 6'd63;

    reg [2:0] state;
    reg [3:0] seq_mem [0:SEQ_LEN-1];
    initial $readmemh(SEQ_FILE, seq_mem);

    reg [7:0]   seq_ptr;
    reg [3:0]   scan_ptr;
    reg         seq_scan_d;
    reg [31:0]  tick_cnt;
    reg         pending, seq_mode_d;
    reg [19:0]  lat_cnt;
    reg [6:0]   us_pre;                 // lat_cnt mod CLK_MHZ
    reg [15:0]  us_bcd;                 // floor(lat_cnt / CLK_MHZ), BCD = microseconds
    reg         eye_l, low_l, eye_prev;
    reg [W-1:0] window;

    assign cnn_start = (state == S_START);
    assign busy      = (state != S_IDLE);
    assign perclos   = ({4'd0, closed_count} * 10'd25) >> 3;

    // ---- one drowsy_ref step (combinational, applied in S_UPDATE) ----
    wire signed [32:0] diff     = cnn_logit0 - cnn_logit1;
    wire        low_now  = low_conf_en && (diff < CONF_MARGIN) && (diff > -CONF_MARGIN);
    wire        eye_eff  = low_l ? eye_prev : eye_l;
    wire        out_bit  = window[W-1];
    wire [5:0]  count_n  = closed_count + eye_eff - out_bit;
    wire [5:0]  crun_n   = eye_eff ? ((closed_run == RUN_MAX) ? RUN_MAX : closed_run + 6'd1) : 6'd0;
    wire [5:0]  orun_n   = eye_eff ? 6'd0 : ((open_run == RUN_MAX) ? RUN_MAX : open_run + 6'd1);
    wire [1:0]  dstate_n =
        (crun_n >= SLEEP_RUN)                                 ? ST_SLEEP :
        (drowsy_state == ST_SLEEP)  ? ((orun_n >= WAKE_RUN) ? ((count_n > DROWSY_OFF) ? ST_DROWSY : ST_AWAKE)
                                                            : ST_SLEEP) :
        (drowsy_state == ST_AWAKE)  ? ((count_n >= DROWSY_ON)  ? ST_DROWSY : ST_AWAKE) :
                                      ((count_n <= DROWSY_OFF) ? ST_AWAKE  : ST_DROWSY);

    function [15:0] bcd_inc;            // BCD +1, saturates at 9999
        input [15:0] b;
        if      (b == 16'h9999)    bcd_inc = b;
        else if (b[3:0]  != 4'd9)  bcd_inc = {b[15:4], b[3:0] + 4'd1};
        else if (b[7:4]  != 4'd9)  bcd_inc = {b[15:8], b[7:4] + 4'd1, 4'd0};
        else if (b[11:8] != 4'd9)  bcd_inc = {b[15:12], b[11:8] + 4'd1, 8'd0};
        else                       bcd_inc = {b[15:12] + 4'd1, 12'd0};
    endfunction

    wire mode_change = (seq_mode != seq_mode_d);
    wire [31:0] period = seq_slow ? SLOW_TICKS : STEP_TICKS;
    wire tick        = seq_mode && !seq_step && (tick_cnt >= period - 1);   // >=: safe when the rate switches
    wire go          = (seq_mode && !seq_step) ? (tick || pending) : start_pulse;

    always @(posedge clk) begin
        if (rst) begin
            state <= S_IDLE; seq_mode_d <= 1'b0; img_slot <= 4'd0; latency <= 20'd0; lat_cnt <= 20'd0;
            latency_us <= 16'd0; us_pre <= 7'd0; us_bcd <= 16'd0;
            eye_l <= 1'b0; low_l <= 1'b0; eye_state <= 1'b0; frame_done <= 1'b0;
        end else begin
            seq_mode_d <= seq_mode;
            frame_done <= 1'b0;
            case (state)
                S_IDLE:   if (go) begin
                              img_slot <= !seq_mode ? slot_sw : seq_scan ? scan_ptr : seq_mem[seq_ptr];
                              state    <= S_START;
                          end
                S_START:  begin lat_cnt <= 20'd1; us_pre <= 7'd1; us_bcd <= 16'd0; state <= S_WAIT; end
                S_WAIT:   if (cnn_done) begin
                              latency    <= lat_cnt;
                              latency_us <= us_bcd;
                              eye_l   <= cnn_eye;
                              low_l   <= low_now;
                              state   <= S_UPDATE;
                          end else if (lat_cnt != 20'hFFFFF) begin
                              lat_cnt <= lat_cnt + 20'd1;
                              us_pre  <= (us_pre == CLK_MHZ - 1) ? 7'd0 : us_pre + 7'd1;
                              if (us_pre == CLK_MHZ - 1) us_bcd <= bcd_inc(us_bcd);
                          end
                S_UPDATE: begin eye_state <= eye_l; state <= S_SHOW; end
                S_SHOW:   begin frame_done <= 1'b1; state <= S_IDLE; end
                default:  state <= S_IDLE;
            endcase
        end
    end

    // drowsiness registers, sequence pointer, step timer (cleared on reset and on a mode change)
    always @(posedge clk) begin
        if (rst || mode_change) begin
            window <= {W{1'b0}}; closed_count <= 6'd0; closed_run <= 6'd0; open_run <= 6'd0;
            eye_prev <= 1'b0; drowsy_state <= ST_AWAKE; have_result <= 1'b0;
            seq_ptr <= 8'd0; tick_cnt <= 32'd0; pending <= 1'b0; scan_ptr <= 4'd0; seq_scan_d <= 1'b0;
        end else begin
            tick_cnt <= (!seq_mode || seq_step || tick) ? 32'd0 : tick_cnt + 32'd1;
            seq_scan_d <= seq_scan;
            if (seq_scan && !seq_scan_d) scan_ptr <= 4'd0;      // scan restarts at slot 0
            if (state == S_IDLE && go) begin
                pending <= 1'b0;
                if (seq_mode && seq_scan)  scan_ptr <= scan_ptr + 4'd1;          // wraps 15 -> 0
                if (seq_mode && !seq_scan) seq_ptr  <= (seq_ptr == SEQ_LEN - 1) ? 8'd0 : seq_ptr + 8'd1;
            end else if (tick) begin
                pending <= 1'b1;            // step tick while busy: run as soon as IDLE
            end
            if (state == S_UPDATE) begin
                window       <= {window[W-2:0], eye_eff};
                closed_count <= count_n;
                closed_run   <= crun_n;
                open_run     <= orun_n;
                drowsy_state <= dstate_n;
                eye_prev     <= eye_eff;
            end
            if (state == S_SHOW) have_result <= 1'b1;
        end
    end
endmodule
