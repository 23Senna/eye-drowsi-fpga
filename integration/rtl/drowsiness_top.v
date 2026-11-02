// drowsiness_top.v - Basys3 top level: driver-drowsiness CNN demo.
// CNN core = the CNN team's cnn_top (eye-drowsi-fpga/rtl/cnn_top.v + rom_weights.v, own image/weight ROMs,
// image chosen by img_base_addr = slot * 1024, prediction 1 = open). Define USE_STUB to build with
// cnn_core_stub (golden logits, fixed latency) plus the integration ROMs instead.
// Clock: the 100 MHz board clock feeds an MMCM that makes the system clock CLK_MHZ (default 50 MHz,
// because cnn_top's conv2 MAC path needs ~16.6 ns). CLK_MHZ = 100 bypasses the MMCM. In simulation
// (no SYNTHESIS macro) the board clock is used directly - testbenches set CLK_MHZ = 100.
module drowsiness_top #(
    parameter CLK_MHZ      = 50,          // 50 or 100
    parameter DEB_CYCLES   = CLK_MHZ * 10000,     // 10 ms debounce
    parameter STEP_TICKS   = CLK_MHZ * 100000,    // 100 ms per sequence frame
    parameter SLOW_TICKS   = CLK_MHZ * 1000000,   // 1 s per frame with SW12 (demo)
    parameter REFRESH_BITS = (CLK_MHZ == 100) ? 18 : 17,   // ~650 us per digit
    parameter BLINK_BITS   = (CLK_MHZ == 100) ? 24 : 23,   // ~6 Hz blink
    parameter STUB_LATENCY = 75826,       // = cnn_top latency (stub build only)
    parameter IMG_FILE     = "images.mem",
    parameter W_FILE       = "weights.mem",
    parameter B_FILE       = "biases.mem",
    parameter SEQ_FILE     = "seq.mem",
    parameter LOGIT_FILE   = "stub_logits.mem"
) (
    input  wire        clk,
    input  wire [15:0] sw,
    input  wire        btnC,
    input  wire        btnU,
    output wire [15:0] led,
    output wire [6:0]  seg,
    output wire        dp,
    output wire [3:0]  an
);
    // ---- system clock ----
    wire sys_clk, locked;
`ifdef SYNTHESIS
    generate if (CLK_MHZ == 100) begin : g_noclk
        assign sys_clk = clk;
        assign locked  = 1'b1;
    end else begin : g_mmcm
        wire fb_unbuf, fb_buf, clk_unbuf;
        // VCO = 100 MHz * 10 = 1000 MHz, CLKOUT0 = 1000 / (1000 / CLK_MHZ)
        MMCME2_BASE #(.CLKIN1_PERIOD(10.0), .DIVCLK_DIVIDE(1), .CLKFBOUT_MULT_F(10.0),
                      .CLKOUT0_DIVIDE_F(1000.0 / CLK_MHZ)) u_mmcm (
            .CLKIN1(clk), .CLKFBIN(fb_buf), .CLKFBOUT(fb_unbuf), .CLKFBOUTB(), .CLKOUT0(clk_unbuf),
            .CLKOUT0B(), .CLKOUT1(), .CLKOUT1B(), .CLKOUT2(), .CLKOUT2B(), .CLKOUT3(), .CLKOUT3B(),
            .CLKOUT4(), .CLKOUT5(), .CLKOUT6(), .LOCKED(locked), .PWRDWN(1'b0), .RST(1'b0));
        BUFG u_fb_bufg  (.I(fb_unbuf),  .O(fb_buf));
        BUFG u_clk_bufg (.I(clk_unbuf), .O(sys_clk));
    end endgenerate
`else
    assign sys_clk = clk;
    assign locked  = 1'b1;
`endif

    wire        rst, start_pulse, low_conf_en, seq_mode, seq_slow, seq_step, seq_scan, lat_view;
    wire [3:0]  slot_sw, img_slot;
    wire        cnn_start, cnn_done, cnn_eye;
    wire signed [31:0] logit0, logit1;     // FC class 0 = closed, class 1 = open
    wire        fsm_busy, frame_done, have_result, eye_state;
    wire [1:0]  drowsy_state;
    wire [5:0]  closed_count, closed_run, open_run;
    wire [6:0]  perclos;
    wire [19:0] latency;
    wire [15:0] latency_us;

    input_control #(.DEB_CYCLES(DEB_CYCLES)) u_input (
        .clk(sys_clk), .btnC(btnC), .btnU(btnU | ~locked), .sw(sw), .rst(rst), .start_pulse(start_pulse),
        .slot(slot_sw), .seq_scan(seq_scan), .seq_step(seq_step), .seq_slow(seq_slow), .low_conf_en(low_conf_en),
        .seq_mode(seq_mode), .lat_view(lat_view));

    drowsy_fsm #(.STEP_TICKS(STEP_TICKS), .SLOW_TICKS(SLOW_TICKS), .SEQ_FILE(SEQ_FILE), .CLK_MHZ(CLK_MHZ)) u_fsm (
        .clk(sys_clk), .rst(rst), .start_pulse(start_pulse), .slot_sw(slot_sw), .seq_mode(seq_mode),
        .seq_slow(seq_slow), .seq_step(seq_step), .seq_scan(seq_scan), .low_conf_en(low_conf_en),
        .cnn_start(cnn_start), .cnn_done(cnn_done), .cnn_eye(cnn_eye),
        .cnn_logit0(logit0), .cnn_logit1(logit1), .img_slot(img_slot), .busy(fsm_busy),
        .frame_done(frame_done), .have_result(have_result), .eye_state(eye_state),
        .drowsy_state(drowsy_state), .closed_count(closed_count), .closed_run(closed_run),
        .open_run(open_run), .perclos(perclos), .latency(latency), .latency_us(latency_us));

`ifdef USE_STUB
    wire [13:0] core_img_addr;
    wire [7:0]  img_data, w_data;
    wire [11:0] w_addr;
    wire [4:0]  b_addr;
    wire [31:0] b_data;
    wire        stub_busy;

    cnn_core_stub #(.LATENCY(STUB_LATENCY), .LOGIT_FILE(LOGIT_FILE)) u_core (
        .clk(sys_clk), .rst(rst), .start(cnn_start), .slot(img_slot), .busy(stub_busy), .done(cnn_done),
        .eye_state(cnn_eye), .logit0(logit0), .logit1(logit1), .img_addr(core_img_addr),
        .img_data(img_data), .w_addr(w_addr), .w_data(w_data), .b_addr(b_addr), .b_data(b_data));

    // slot bits of the image address come from the Drowsy FSM
    image_rom #(.MEM_FILE(IMG_FILE)) u_img (
        .clk(sys_clk), .addr({img_slot, core_img_addr[9:0]}), .data(img_data));

    weight_bias_rom #(.W_FILE(W_FILE), .B_FILE(B_FILE)) u_wb (
        .clk(sys_clk), .w_addr(w_addr), .w_data(w_data), .b_addr(b_addr), .b_data(b_data));
`else
    wire prediction;                       // cnn_top: 1 = open, 0 = closed (tie -> closed)

    cnn_top u_core (
        .clk(sys_clk), .rst(rst), .start(cnn_start), .img_base_addr({img_slot, 10'b0}),
        .done(cnn_done), .prediction(prediction), .logit0(logit0), .logit1(logit1));

    assign cnn_eye = ~prediction;          // eye_state 1 = closed
`endif

    alert_control #(.REFRESH_BITS(REFRESH_BITS), .BLINK_BITS(BLINK_BITS)) u_alert (
        .clk(sys_clk), .rst(rst), .have_result(have_result), .eye_state(eye_state),
        .drowsy_state(drowsy_state), .closed_count(closed_count), .seq_mode(seq_mode), .seq_scan(seq_scan),
        .lat_view(lat_view), .busy(fsm_busy), .slot(img_slot), .latency(latency_us),
        .led(led), .seg(seg), .dp(dp), .an(an));
endmodule
