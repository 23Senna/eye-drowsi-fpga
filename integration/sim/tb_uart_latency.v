`timescale 1ns/1ps
module tb_uart_latency;
    parameter MHZ=100;
    reg clk=0,rst=1,cnn_start=0,frame_done=0,system_busy=0;
    reg [19:0] latency=0;
    wire tx,ready,quiet,run_pending;wire [3:0] pc_slot;
    wire [7:0] data;wire valid,fe;
    integer lines=0,i,before_line;
    reg [19:0] values[0:5];reg [1279:0] line=0,last_line=0,expected;
    always #5 clk=~clk;
    uart_monitor #(.CLKS_PER_BIT(16),.CLK_MHZ(MHZ)) dut(
        .clk(clk),.rst(rst),.rx(1'b1),.tx(tx),.pc_mode(1'b0),.mode_pending(1'b0),
        .system_busy(system_busy),.cnn_start(cnn_start),.sequence_mode(1'b0),.frame_done(frame_done),
        .image_slot(4'd15),.closed(1'b1),.warning_state(2'd2),.logit0(-32'sd123),.logit1(32'sd0),
        .latency(latency),.pc_slot(pc_slot),.run_pending(run_pending),.launch_ready(ready),.quiescent(quiet));
    uart_rx #(.CLKS_PER_BIT(16)) decode(.clk(clk),.rst(rst),.rx(tx),.data(data),.valid(valid),.framing_error(fe));
    always @(negedge clk)if(valid)begin
        if(data==10)begin last_line=line;line=0;lines=lines+1;end
        else if(data!=13)line=(line<<8)|data;
    end
    initial begin
        values[0]=0;values[1]=99;values[2]=100;values[3]=101;values[4]=37290;values[5]=20'hfffff;
        repeat(5)@(negedge clk);rst=0;
        for(i=0;i<6;i=i+1)begin
            @(negedge clk);while(!quiet)@(negedge clk);
            latency=values[i];cnn_start=1;system_busy=1;before_line=lines;
            @(negedge clk);cnn_start=0;
            @(negedge clk);frame_done=1;system_busy=0;
            @(negedge clk);frame_done=0;
            wait(lines==before_line+1);
            $sformat(expected,"RESULT source=BOARD slot=15 class=CLOSED warning=MICROSLEEP logit0=-123 logit1=0 cycles=%0d us=%0d",values[i],values[i]/MHZ);
            if(last_line!==expected)$fatal(1,"latency conversion mismatch: %0s",last_line);
        end
        $display("PASS tb_uart_latency (MHz=%0d, zero, rounding boundaries and maximum cycle count)",MHZ);$finish;
    end
    initial begin #2000000;$fatal(1,"latency timeout");end
endmodule
