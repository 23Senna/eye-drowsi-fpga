`timescale 1ns/1ps
module tb_uart_command;
    reg clk=0,rst=1,valid=0,fe=0;reg [7:0] data=0;
    wire cv;wire [2:0] kind;wire [3:0] slot;
    integer i,j,events=0;reg [2:0] last_kind;reg [3:0] last_slot;
    always #5 clk=~clk;
    uart_command dut(.clk(clk),.rst(rst),.data(data),.valid(valid),.framing_error(fe),.command_valid(cv),.kind(kind),.slot(slot));
    always @(negedge clk)if(cv)begin events=events+1;last_kind=kind;last_slot=slot;end
    task byte_in(input [7:0] b);
        begin @(negedge clk);data=b;valid=1;@(negedge clk);valid=0;@(negedge clk);end
    endtask
    task cmd(input string s,input [2:0] expected_kind,input [3:0] expected_slot);
        integer n,before_event;
        begin
            before_event=events;
            for(n=0;n<s.len();n=n+1)byte_in(s[n]);
            repeat(3)@(negedge clk);
            if(events!=before_event+1||last_kind!==expected_kind||(expected_kind==0&&last_slot!==expected_slot))begin
                $display("command %s: kind=%0d slot=%0d len=%0d number=%0d",s,last_kind,last_slot,dut.length,dut.number);
                $fatal(1,"parser mismatch");
            end
        end
    endtask
    initial begin
        repeat(4)@(negedge clk);rst=0;
        cmd("SLOT 16\n",3,0);
        for(i=0;i<16;i=i+1)cmd($sformatf("SLOT %0d\015\n",i),0,i);
        cmd("RUN\n",1,0);cmd("run\n",2,0);cmd("SLOT -1\n",3,0);cmd("SLOT 999\n",3,0);
        cmd("SLOT 00\n",0,0);cmd("SLOT 15\n",0,15);cmd("RU\015N\n",2,0);
        for(j=0;j<33;j=j+1)byte_in("X");cmd("\n",4,0);
        @(negedge clk);fe=1;@(negedge clk);fe=0;cmd("RUN\n",5,0);cmd("RUN\n",1,0);
        byte_in("S");@(negedge clk);rst=1;@(negedge clk);rst=0;cmd("RUN\n",1,0);
        $display("PASS tb_uart_command (all slots, LF/CRLF, range, overflow, framing, reset)");$finish;
    end
    initial begin #100000;$fatal(1,"parser timeout");end
endmodule
