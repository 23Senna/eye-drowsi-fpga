`timescale 1ns/1ps
module tb_uart_format;
    reg clk=0,rst=1,start=0;reg [3:0] message=0,slot=15;
    reg [1:0] source=1,warning_state=2;reg closed=1;
    reg signed [31:0] l0=32'sh80000000,l1=32'sh7fffffff;
    reg [31:0] cycles=32'hffffffff,us=0;
    wire ready,done,tx,rv,fe;wire [7:0] rd;
    reg [1279:0] accum=0,last_line=0;
    integer lines=0,before_line,i;
    always #5 clk=~clk;
    uart_ascii_tx #(.CLKS_PER_BIT(16)) dut(.clk(clk),.rst(rst),.start(start),.message(message),.slot(slot),
        .source(source),.closed(closed),.warning_state(warning_state),.logit0(l0),.logit1(l1),
        .cycles(cycles),.microseconds(us),.ready(ready),.done(done),.tx(tx));
    uart_rx #(.CLKS_PER_BIT(16)) decode(.clk(clk),.rst(rst),.rx(tx),.data(rd),.valid(rv),.framing_error(fe));
    always @(negedge clk)begin
        if(fe)$fatal(1,"TX framing error");
        if(rv)begin
            if(rd==10)begin last_line=accum;accum=0;lines=lines+1;end
            else if(rd!=13)accum=(accum<<8)|rd;
        end
    end
    task send(input [3:0] code,input [1279:0] expected);
        begin
            wait(ready);@(negedge clk);message=code;start=1;before_line=lines;
            @(negedge clk);start=0;
            wait(lines==before_line+1);
            if(last_line!==expected)begin $display("got: %0s expected: %0s",last_line,expected);$fatal(1,"format mismatch");end
            wait(done);@(negedge clk);
        end
    endtask
    initial begin
        repeat(5)@(negedge clk);rst=0;
        send(0,"RESULT source=PC slot=15 class=CLOSED warning=MICROSLEEP logit0=-2147483648 logit1=2147483647 cycles=4294967295 us=0");
        source=0;warning_state=0;closed=0;l0=0;l1=-1;slot=0;cycles=0;us=372;
        send(0,"RESULT source=BOARD slot=0 class=OPEN warning=AWAKE logit0=0 logit1=-1 cycles=0 us=372");
        source=2;warning_state=1;
        send(0,"RESULT source=SEQ slot=0 class=OPEN warning=DROWSY logit0=0 logit1=-1 cycles=0 us=372");
        send(1,"OK SLOT 0");send(2,"OK RUN");send(3,"ERR MODE");send(4,"ERR BUSY");
        send(5,"ERR CMD");send(6,"ERR RANGE");send(7,"ERR OVERFLOW");send(8,"ERR FRAME");send(9,"ERR OVERRUN");
        wait(ready);@(negedge clk);start=1;message=0;@(negedge clk);start=0;
        repeat(40)@(negedge clk);rst=1;repeat(5)@(negedge clk);rst=0;accum=0;
        send(2,"OK RUN");
        $display("PASS tb_uart_format (all messages, signed extremes, decimal, reset)");$finish;
    end
    initial begin #3000000;$fatal(1,"format timeout");end
endmodule
