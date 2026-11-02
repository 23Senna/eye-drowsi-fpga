// alert_control.v - 4-digit 7-segment text + LED patterns.
// Basys3: seg[6:0] = {g,f,e,d,c,b,a}, an[3:0] (an[3] = leftmost), dp - all active low.
// Text priority: lat_view -> latency (4 BCD digits, microseconds); no result -> "----";
//   sequence mode: MICROSLEEP -> "SLEP", DROWSY -> "tirE"; otherwise "OPEn" / "CLSd".
//   seq_scan (slots in order, for comparing with manual mode): always "OPEn" / "CLSd" (state only on LD14/15).
// LEDs: [3:0] slot, [4] busy, [5] eye closed, [6] seq mode, [13:7] PERCLOS bar (count > 4i, i = 0..6),
//       [14] DROWSY, [15] MICROSLEEP (blinks with blink counter bit BLINK_BITS-1).
module alert_control #(
    parameter REFRESH_BITS = 18,  // digit period = 2^(REFRESH_BITS-2) cycles
    parameter BLINK_BITS   = 24   // blink period = 2^BLINK_BITS cycles (~6 Hz @ 100 MHz)
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        have_result,
    input  wire        eye_state,
    input  wire [1:0]  drowsy_state,   // 0 AWAKE, 1 DROWSY, 2 MICROSLEEP
    input  wire [5:0]  closed_count,
    input  wire        seq_mode,
    input  wire        seq_scan,
    input  wire        lat_view,
    input  wire        busy,
    input  wire [3:0]  slot,
    input  wire [15:0] latency,        // BCD digits, shown as is
    output reg  [15:0] led,
    output reg  [6:0]  seg,
    output reg         dp,
    output reg  [3:0]  an
);
    // glyphs, active high {g,f,e,d,c,b,a}
    localparam [6:0] G_O = 7'h3F, G_P = 7'h73, G_E = 7'h79, G_N = 7'h54,
                     G_C = 7'h39, G_L = 7'h38, G_S = 7'h6D, G_D = 7'h5E,
                     G_T = 7'h78, G_I = 7'h04, G_R = 7'h50, G_DASH = 7'h40;

    function [6:0] hex7;
        input [3:0] h;
        case (h)
            4'h0: hex7 = 7'h3F; 4'h1: hex7 = 7'h06; 4'h2: hex7 = 7'h5B; 4'h3: hex7 = 7'h4F;
            4'h4: hex7 = 7'h66; 4'h5: hex7 = 7'h6D; 4'h6: hex7 = 7'h7D; 4'h7: hex7 = 7'h07;
            4'h8: hex7 = 7'h7F; 4'h9: hex7 = 7'h6F; 4'hA: hex7 = 7'h77; 4'hB: hex7 = 7'h7C;
            4'hC: hex7 = 7'h39; 4'hD: hex7 = 7'h5E; 4'hE: hex7 = 7'h79; default: hex7 = 7'h71;
        endcase
    endfunction

    // text for digits 3 (left) .. 0 (right)
    // continuous assigns (not always @*) so the text is valid from time 0 in simulation
    wire [27:0] text =
        lat_view                          ? {hex7(latency[15:12]), hex7(latency[11:8]),
                                             hex7(latency[7:4]),   hex7(latency[3:0])} :
        !have_result                      ? {G_DASH, G_DASH, G_DASH, G_DASH} :
        (seq_mode && !seq_scan && drowsy_state == 2'd2) ? {G_S, G_L, G_E, G_P} :
        (seq_mode && !seq_scan && drowsy_state == 2'd1) ? {G_T, G_I, G_R, G_E} :
        eye_state                         ? {G_C, G_L, G_S, G_D} :
                                            {G_O, G_P, G_E, G_N};

    reg [REFRESH_BITS-1:0] refresh;
    reg [BLINK_BITS-1:0]   blink;
    wire [1:0] digit = refresh[REFRESH_BITS-1:REFRESH_BITS-2];

    wire [6:0] bar = {closed_count > 24, closed_count > 20, closed_count > 16, closed_count > 12,
                      closed_count > 8,  closed_count > 4,  closed_count > 0};

    always @(posedge clk) begin
        if (rst) begin
            refresh <= 0;
            blink   <= 0;
            seg     <= 7'h7F;
            an      <= 4'hF;
            dp      <= 1'b1;
            led     <= 16'h0000;
        end else begin
            refresh <= refresh + 1'b1;
            blink   <= blink + 1'b1;
            an      <= ~(4'b0001 << digit);
            seg     <= ~text[digit*7 +: 7];
            dp      <= ~(seq_mode && digit == 2'd0);   // dot on the right digit = sequence mode
            led     <= {(drowsy_state == 2'd2) & blink[BLINK_BITS-1], (drowsy_state == 2'd1),
                        bar, seq_mode, eye_state & have_result, busy, slot};
        end
    end
endmodule
