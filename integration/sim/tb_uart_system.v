`timescale 1ns/1ps
`include "tb_paths.vh"
// End-to-end commands and results through physical serial pins, real or stub CNN.
module tb_uart_system;
    localparam CPB=64;
`ifdef USE_STUB
    localparam LAT=40;
`else
    localparam LAT=7996;
`endif
    reg clk=0,btnC=0,btnU=0,rx=1;
    reg [15:0] sw=0;
    wire tx;wire [15:0] led;wire [6:0] seg;wire dp;wire [3:0] an;
    drowsiness_top #(.UART_BAUD(1562500),.DEB_CYCLES(4),.STUB_LATENCY(LAT),
        .STEP_TICKS(500),.SLOW_TICKS(1000),.REFRESH_BITS(6),.BLINK_BITS(8),
        .IMG_FILE(`MEM("images.mem")),.W_FILE(`MEM("weights.mem")),.B_FILE(`MEM("biases.mem")),
        .SEQ_FILE(`MEM("seq.mem")),.LOGIT_FILE(`MEM("stub_logits.mem"))) dut(
        .clk(clk),.btnC(btnC),.btnU(btnU),.sw(sw),.uart_rx(rx),.uart_tx(tx),.led(led),.seg(seg),.dp(dp),.an(an));
    always #5 clk=~clk;
    wire [7:0] decoded;wire decoded_valid,decoded_error;
    uart_rx #(.CLKS_PER_BIT(CPB)) decode(.clk(clk),.rst(dut.rst),.rx(tx),.data(decoded),.valid(decoded_valid),.framing_error(decoded_error));
    reg [47:0] golden[0:15];
    reg [1279:0] actual_line=0,lines[0:511],expected_lines[0:511];
    reg [1279:0] source_text,class_text,warning_text,expected_response,expected_frame;
    integer n_lines=0,read_line=0,n_expected=0,n_result=0,n_bad=0,n_overrun=0;
    integer i,j,target,g0,g1,eye,effective,count=0,crun=0,orun=0,status=0,previous=0;
    reg [31:0] window=0;reg prev_sequence=0;
    reg [1:0] frame_source=0;
    function integer sx24(input [23:0] b);sx24=b[23]?b-24'hffffff-1:b;endfunction

    // Independent temporal oracle driven by golden predictions, one step per completed frame.
    always @(negedge clk) begin
        if(dut.rst) begin
            window=0;count=0;crun=0;orun=0;status=0;previous=0;prev_sequence=0;
            actual_line=0;n_result=n_expected;
        end else begin
            if(dut.seq_mode!=prev_sequence)begin window=0;count=0;crun=0;orun=0;status=0;previous=0;end
            prev_sequence=dut.seq_mode;
            if(dut.cnn_start)frame_source=dut.pc_mode?1:dut.seq_mode?2:0;
            if(dut.frame_done)begin
                g0=sx24(golden[dut.img_slot][47:24]);g1=sx24(golden[dut.img_slot][23:0]);
                eye=(g0>=g1);effective=eye;
                if(dut.low_conf_en && (g0-g1<1024) && (g0-g1> -1024))effective=previous;
                count=count+effective-window[31];window=(window<<1)|effective;
                crun=effective?((crun<63)?crun+1:63):0;
                orun=effective?0:((orun<63)?orun+1:63);
                if(crun>=8)status=2;
                else if(status==2)begin if(orun>=10)status=(count>6)?1:0;end
                else if(status==0)begin if(count>=13)status=1;end
                else if(count<=6)status=0;
                previous=effective;
                source_text=(frame_source==1)?"PC":(frame_source==2)?"SEQ":"BOARD";
                class_text=eye?"CLOSED":"OPEN";
                warning_text=(status==2)?"MICROSLEEP":(status==1)?"DROWSY":"AWAKE";
                $sformat(expected_frame,"RESULT source=%0s slot=%0d class=%0s warning=%0s logit0=%0d logit1=%0d cycles=%0d us=%0d",
                    source_text,dut.img_slot,class_text,warning_text,g0,g1,LAT,LAT/100);
                expected_lines[n_expected]=expected_frame;n_expected=n_expected+1;
            end
            if(decoded_error)$fatal(1,"invalid TX stop bit");
            if(decoded_valid)begin
                if(decoded==10)begin
                    lines[n_lines]=actual_line;n_lines=n_lines+1;
                    if(actual_line=="ERR OVERRUN")n_overrun=n_overrun+1;
                    // RESULT lines are long enough to distinguish from all replies.
                    if(actual_line[1279:8*20]!=0)begin
                        if(n_result>=n_expected || actual_line!==expected_lines[n_result])begin
                            $display("got: %0s\nexp: %0s",actual_line,expected_lines[n_result]);$fatal(1,"serial result mismatch #%0d",n_result);
                        end
                        n_result=n_result+1;
                    end
                    actual_line=0;
                end else if(decoded!=13)actual_line=(actual_line<<8)|decoded;
            end
        end
    end
    task byte_in(input [7:0] b,input bad_stop);
        integer k;
        begin
            @(negedge clk);rx=0;repeat(CPB)@(negedge clk);
            for(k=0;k<8;k=k+1)begin rx=b[k];repeat(CPB)@(negedge clk);end
            rx=!bad_stop;repeat(CPB)@(negedge clk);rx=1;
        end
    endtask
    task command(input string s);
        integer k;
        begin for(k=0;k<s.len();k=k+1)byte_in(s[k],0);end
    endtask
    task expect_reply(input [1279:0] s);
        begin
            wait(n_lines>read_line);
            while(lines[read_line][1279:8*20]!=0)begin read_line=read_line+1;wait(n_lines>read_line);end
            if(lines[read_line]!==s)begin $display("reply got %0s expected %0s",lines[read_line],s);$fatal(1,"reply mismatch");end
            read_line=read_line+1;
        end
    endtask
    task quiet;
        begin
            @(negedge clk);
            while(!dut.serial_quiescent || dut.fsm_busy)@(negedge clk);
            repeat(5)@(negedge clk);
        end
    endtask
    initial begin
        $readmemh(`MEM("stub_logits.mem"),golden);
        btnU=1;repeat(10)@(negedge clk);btnU=0;repeat(30)@(negedge clk);
        command("RUN\n");expect_reply("ERR MODE");quiet;
        command("SLOT 16\n");expect_reply("ERR RANGE");quiet;
        command("run\n");expect_reply("ERR CMD");quiet;
        for(i=0;i<40;i=i+1)byte_in("X",0);byte_in(10,0);expect_reply("ERR OVERFLOW");quiet;
        byte_in("R",1);repeat(CPB*2)@(negedge clk);byte_in(10,0);expect_reply("ERR FRAME");quiet;
        // Overload the one-reply mailbox before starting any image sequence.
        for(i=0;i<20;i=i+1)command("X\n");
        quiet;
        if(n_overrun==0)begin
            for(j=0;j<n_lines;j=j+1)$display("reply[%0d]=%0s",j,lines[j]);
            $fatal(1,"command flood not reported");
        end
        read_line=n_lines;
        sw[9]=1;sw[14]=1;repeat(30)@(negedge clk);wait(dut.pc_mode);
        if(dut.seq_mode)$fatal(1,"PC did not mask sequence switch");
        for(i=0;i<16;i=i+1)begin
            command($sformatf("SLOT %0d\015\n",i));$sformat(expected_response,"OK SLOT %0d",i);expect_reply(expected_response);quiet;
            target=n_result+1;command("RUN\n");expect_reply("OK RUN");
            if(i==0)begin
                command("RUN\n");expect_reply("ERR BUSY");
                btnC=1;repeat(20)@(negedge clk);btnC=0;
            end
            if(i==1)begin command("SLOT 15\n");expect_reply("ERR BUSY");end
            wait(n_result==target);quiet;
        end
        if(n_expected!=16)$fatal(1,"button or sequence interfered in PC mode");
        // New export: slot 0 is raw OPEN with a margin below CONF_MARGIN.
        // Hold a previous CLOSED observation while still reporting raw class/logits.
        command("SLOT 2\n");expect_reply("OK SLOT 2");quiet;
        target=n_result+1;command("RUN\n");expect_reply("OK RUN");wait(n_result==target);quiet;
        if(dut.closed_run==0)$fatal(1,"CLOSED setup observation missing");
        sw[13]=1;repeat(30)@(negedge clk);
        command("SLOT 0\n");expect_reply("OK SLOT 0");quiet;
        target=n_result+1;command("RUN\n");expect_reply("OK RUN");wait(n_result==target);quiet;
        if(dut.eye_state!==0 || dut.closed_run<2)$fatal(1,"low-confidence raw class/hold mismatch");
        sw[13]=0;repeat(30)@(negedge clk);
        target=n_result+1;command("RUN\n");expect_reply("OK RUN");wait(n_result==target);quiet;
        if(dut.closed_run!=0)$fatal(1,"low-confidence hold did not release");
        // A mode request cannot cancel the active transmission/inference.
        command("RUN\n");expect_reply("OK RUN");target=n_result+1;
        sw[14]=0;sw[9]=0;repeat(30)@(negedge clk);
        if(!dut.pc_mode)$fatal(1,"mode changed before RESULT completed");
        wait(n_result==target);quiet;wait(!dut.pc_mode);
        read_line=n_lines;
        // Single manual board frame, then throttled sequence (timer much faster than UART).
        sw[3:0]=3;repeat(30)@(negedge clk);target=n_result+1;
        btnC=1;repeat(20)@(negedge clk);btnC=0;wait(n_result==target);quiet;
        target=n_result+64;sw[14]=1;repeat(30)@(negedge clk);
        wait(n_result==target);sw[14]=0;repeat(30)@(negedge clk);quiet;
        // Flood invalid requests: coalesced overrun, no extra PC requests.
        read_line=n_lines;
        quiet;
        read_line=n_lines;
        command("RUN\n");expect_reply("ERR MODE");quiet;
        // Reset aborts a partial line and restores a usable protocol.
        command("SLO");btnU=1;repeat(15)@(negedge clk);btnU=0;repeat(30)@(negedge clk);
        read_line=n_lines;sw[9]=1;repeat(30)@(negedge clk);wait(dut.pc_mode);
        command("SLOT 0\n");expect_reply("OK SLOT 0");quiet;
        command("RUN\n");expect_reply("OK RUN");target=n_result+1;wait(n_result==target);quiet;
        // Abort an active request before its acknowledgement/result can complete.
        command("RUN\n");btnU=1;repeat(15)@(negedge clk);btnU=0;repeat(30)@(negedge clk);
        read_line=n_lines;wait(dut.pc_mode);
        command("RUN\n");expect_reply("OK RUN");target=n_result+1;wait(n_result==target);quiet;
        $display("PASS tb_uart_system (16 PC slots, BOARD/SEQ telemetry, golden/temporal oracle, low-confidence hold, busy, mode, errors, overrun, reset; results=%0d)",n_result);$finish;
    end
    initial begin #200000000;$fatal(1,"UART system timeout: lines=%0d expected=%0d result=%0d",n_lines,n_expected,n_result);end
endmodule
