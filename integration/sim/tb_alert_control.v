`timescale 1ns/1ps
// tb_alert_control.v - decodes the multiplexed display and checks each text mode + LEDs.
module tb_alert_control;
    localparam RB = 4;   // digit period 4 cycles
    reg clk = 0, rst = 1;
    reg have_result = 0, eye_state = 0, seq_mode = 0, seq_scan = 0, lat_view = 0, busy = 0;
    reg [1:0] drowsy_state = 0;
    reg [5:0] closed_count = 0;
    reg [3:0] slot = 0;
    reg [15:0] latency = 16'h0ED8;
    wire [15:0] led; wire [6:0] seg; wire dp; wire [3:0] an;
    integer errors = 0, k;
    reg [27:0] shown;

    alert_control #(.REFRESH_BITS(RB), .BLINK_BITS(3)) dut (
        .clk(clk), .rst(rst), .have_result(have_result), .eye_state(eye_state),
        .drowsy_state(drowsy_state), .closed_count(closed_count), .seq_mode(seq_mode), .seq_scan(seq_scan),
        .lat_view(lat_view), .busy(busy), .slot(slot), .latency(latency),
        .led(led), .seg(seg), .dp(dp), .an(an));

    always #5 clk = ~clk;

    // capture one full refresh frame (active-high glyphs, digit 3 left)
    task grab;
        begin
            repeat (2 << RB) begin
                @(negedge clk);
                case (an)
                    4'b1110: shown[6:0]   = ~seg;
                    4'b1101: shown[13:7]  = ~seg;
                    4'b1011: shown[20:14] = ~seg;
                    4'b0111: shown[27:21] = ~seg;
                endcase
            end
        end
    endtask

    task expect_text(input [27:0] exp, input [8*8-1:0] name);
        begin
            grab;
            if (shown !== exp) begin
                errors = errors + 1;
                $display("FAIL: text %0s got %h exp %h", name, shown, exp);
            end
        end
    endtask

    initial begin
        repeat (3) @(negedge clk); rst = 0;
        expect_text({7'h40, 7'h40, 7'h40, 7'h40}, "----");
        have_result = 1;
        expect_text({7'h3F, 7'h73, 7'h79, 7'h54}, "OPEn");
        eye_state = 1;
        expect_text({7'h39, 7'h38, 7'h6D, 7'h5E}, "CLSd");
        drowsy_state = 1;                       // manual mode ignores drowsy state
        expect_text({7'h39, 7'h38, 7'h6D, 7'h5E}, "CLSd/man");
        seq_mode = 1;
        expect_text({7'h78, 7'h04, 7'h50, 7'h79}, "tirE");
        drowsy_state = 2;
        expect_text({7'h6D, 7'h38, 7'h79, 7'h73}, "SLEP");
        seq_scan = 1;                           // scan order: eye result, not the drowsy state
        expect_text({7'h39, 7'h38, 7'h6D, 7'h5E}, "CLSd/scn");
        seq_scan = 0;
        lat_view = 1;
        expect_text({7'h3F, 7'h79, 7'h5E, 7'h7F}, "0Ed8");

        // LEDs
        slot = 4'd11; busy = 1; closed_count = 6'd13; drowsy_state = 1;
        repeat (2) @(negedge clk);
        // bar: count 13 > 0,4,8,12 -> 4 of 7 LEDs
        if (led[14:0] !== {1'b1, 7'b000_1111, 1'b1, 1'b1, 1'b1, 4'd11}) begin
            errors = errors + 1; $display("FAIL: led %b", led);
        end
        drowsy_state = 2; k = 0;
        repeat (32) begin @(negedge clk); k = k + led[15]; end
        if (k == 0 || k == 32) begin errors = errors + 1; $display("FAIL: led15 not blinking"); end

        if (errors == 0) $display("PASS tb_alert_control");
        else             $display("FAIL tb_alert_control: %0d errors", errors);
        $finish;
    end
endmodule
