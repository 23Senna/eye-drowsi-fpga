`timescale 1ns/1ps
module tb_uart_phy;
    localparam CPB=100;
    reg clk=0,rst=1,valid=0,manual=0,line=1;
    reg [7:0] data=0;
    wire tx,ready,rv,fe; wire [7:0] rd;
    integer received=0,errors=0,i,n0; reg [7:0] last;
    always #5 clk=~clk;
    uart_tx #(.CLKS_PER_BIT(CPB)) t(.clk(clk),.rst(rst),.data(data),.valid(valid),.ready(ready),.tx(tx));
    uart_rx #(.CLKS_PER_BIT(CPB)) r(.clk(clk),.rst(rst),.rx(manual?line:tx),.data(rd),.valid(rv),.framing_error(fe));
    always @(negedge clk) begin
        if(rv) begin received=received+1; last=rd; end
        if(fe) errors=errors+1;
    end
    task loop_byte(input [7:0] b);
        begin
            wait(ready); @(negedge clk);data=b;valid=1;
            @(negedge clk);valid=0;n0=received;
            wait(received==n0+1);if(last!==b)$fatal(1,"loopback mismatch");
        end
    endtask
    task drive_byte(input [7:0] b,input integer ns,input bad_stop);
        integer k;
        begin
            @(negedge clk);line=0;#(ns);
            for(k=0;k<8;k=k+1)begin line=b[k];#(ns);end
            line=!bad_stop;#(ns);line=1;#(2*ns);
        end
    endtask
    initial begin
        repeat(5)@(negedge clk);rst=0;
        loop_byte(0);loop_byte(255);loop_byte(8'h55);loop_byte(8'haa);
        for(i=0;i<20;i=i+1)loop_byte($random);
        wait(ready);manual=1;n0=received;
        line=0;#100;line=1;#2000;
        if(received!=n0||errors!=0)$fatal(1,"false start accepted");
        drive_byte(8'h96,980,0);if(received!=n0+1||last!==8'h96)$fatal(1,"-2 percent baud");
        drive_byte(8'h69,1020,0);if(received!=n0+2||last!==8'h69)$fatal(1,"+2 percent baud");
        drive_byte(8'h00,1000,1);if(errors==0)$fatal(1,"stop error missing");
        n0=received;drive_byte(8'h45,1000,0);if(received!=n0+1||last!==8'h45)$fatal(1,"framing recovery");
        manual=0;wait(ready);@(negedge clk);data=8'hff;valid=1;
        @(negedge clk);valid=0;repeat(30)@(negedge clk);rst=1;
        repeat(3)@(negedge clk);if(!ready||tx!==1)$fatal(1,"reset did not abort TX");
        rst=0;loop_byte(8'h37);
        $display("PASS tb_uart_phy (loopback, baud tolerance, false start, framing, reset)");$finish;
    end
    initial begin #1000000;$fatal(1,"PHY timeout");end
endmodule
