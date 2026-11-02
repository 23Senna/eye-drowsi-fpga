// input_control.v - Basys3 buttons / switches for the drowsiness demo.
//   btnU -> 2-FF sync + power-on hold -> rst (active high, synchronous use)
//   btnC -> 2-FF sync -> debounce -> 1-cycle start_pulse on press
//   SW[3:0] slot, SW[10] sequence scan (slots 0..15 in order), SW[11] sequence step (btnC = next frame), SW[12] slow sequence (1 s/frame),
//   SW[13] low-confidence hold, SW[14] sequence mode, SW[15] latency view
//   (switches: 2-FF sync + debounce as one vector)
// DEB_CYCLES = stable time before a new level is accepted (1_000_000 = 10 ms @ 100 MHz).
module input_control #(
    parameter DEB_CYCLES = 1000000
) (
    input  wire        clk,
    input  wire        btnC,
    input  wire        btnU,
    input  wire [15:0] sw,
    output wire        rst,
    output reg         start_pulse,
    output wire [3:0]  slot,
    output wire        seq_scan,
    output wire        seq_step,
    output wire        seq_slow,
    output wire        low_conf_en,
    output wire        seq_mode,
    output wire        lat_view
);
    // ---- reset: synchronizer + power-on hold (register init values work on 7-series) ----
    reg [1:0] rst_ff  = 2'b11;
    reg [3:0] por_cnt = 4'd0;
    always @(posedge clk) begin
        rst_ff <= {rst_ff[0], btnU};
        if (por_cnt != 4'hF) por_cnt <= por_cnt + 4'd1;
    end
    assign rst = rst_ff[1] | (por_cnt != 4'hF);

    // ---- btnC: sync, debounce, rising-edge pulse ----
    reg [1:0]  btn_ff;
    reg        btn_stable;
    reg [23:0] btn_cnt;
    always @(posedge clk) begin
        if (rst) begin
            btn_ff      <= 2'b00;
            btn_stable  <= 1'b0;
            btn_cnt     <= 24'd0;
            start_pulse <= 1'b0;
        end else begin
            btn_ff      <= {btn_ff[0], btnC};
            start_pulse <= 1'b0;
            if (btn_ff[1] == btn_stable) begin
                btn_cnt <= 24'd0;
            end else if (btn_cnt == DEB_CYCLES - 1) begin
                btn_cnt     <= 24'd0;
                btn_stable  <= btn_ff[1];
                start_pulse <= btn_ff[1];
            end else begin
                btn_cnt <= btn_cnt + 24'd1;
            end
        end
    end

    // ---- switches used: {15..10, 3..0} ----
    wire [9:0] sw_raw = {sw[15:10], sw[3:0]};
    reg  [9:0] sw_ff1, sw_ff2, sw_stable;
    reg [23:0] sw_cnt;
    always @(posedge clk) begin
        if (rst) begin
            sw_ff1    <= 10'd0;
            sw_ff2    <= 10'd0;
            sw_stable <= 10'd0;
            sw_cnt    <= 24'd0;
        end else begin
            sw_ff1 <= sw_raw;
            sw_ff2 <= sw_ff1;
            if (sw_ff2 == sw_stable) begin
                sw_cnt <= 24'd0;
            end else if (sw_cnt == DEB_CYCLES - 1) begin
                sw_cnt    <= 24'd0;
                sw_stable <= sw_ff2;
            end else begin
                sw_cnt <= sw_cnt + 24'd1;
            end
        end
    end
    assign slot        = sw_stable[3:0];
    assign seq_scan    = sw_stable[4];
    assign seq_step    = sw_stable[5];
    assign seq_slow    = sw_stable[6];
    assign low_conf_en = sw_stable[7];
    assign seq_mode    = sw_stable[8];
    assign lat_view    = sw_stable[9];
endmodule
