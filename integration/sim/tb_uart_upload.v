`timescale 1ns/1ps
`include "tb_paths.vh"
module tb_uart_upload;
    localparam CPB=16, N=37;
    reg clk=0, btnU=1, btnC=0, rx=1;
    reg [15:0] sw=0;
    wire tx;
    wire [15:0] led;
    wire [6:0] seg;
    wire dp;
    wire [3:0] an;
    drowsiness_top #(.UART_BAUD(6250000),.DEB_CYCLES(4),
        .UPLOAD_TIMEOUT(10000),.UPLOAD_DRAIN(1000),.REFRESH_BITS(6),.SEQ_FILE(`MEM("seq.mem"))) dut (
        .clk(clk),.sw(sw),.btnU(btnU),.btnC(btnC),.uart_rx(rx),.uart_tx(tx),
        .led(led),.seg(seg),.dp(dp),.an(an));
    always #5 clk=~clk;
    wire [7:0] decoded;
    wire decoded_valid, decoded_error;
    uart_rx #(.CLKS_PER_BIT(CPB)) decoder(.clk(clk),.rst(dut.rst),.rx(tx),
        .data(decoded),.valid(decoded_valid),.framing_error(decoded_error));
    reg [7:0] pixels[0:N*576-1];
    reg [63:0] logits[0:N-1];
    reg [1:0] warnings[0:N-1];
    reg [15:0] golden_crc[0:N-1];
    reg [1599:0] lines[0:511], line=0, expected;
    reg [127:0] class_text, warning_text;
    integer nlines=0, nextline=0, starts=0, results=0, i,j,before_count;
    reg [15:0] crc;
    reg [15:0] frameid;
    reg signed [31:0] l0,l1;
    always @(negedge clk) begin
        if (dut.cnn_start) starts=starts+1;
        if (dut.frame_done) results=results+1;
        if (decoded_error) $fatal(1,"UART TX framing error");
        if (decoded_valid) begin
            if (decoded==10) begin lines[nlines]=line; nlines=nlines+1; line=0; end
            else if (decoded!=13) line=(line<<8)|decoded;
        end
    end
    function [15:0] update_crc;
        input [15:0] c0;
        input [7:0] d;
        integer k;
        reg [15:0] c;
        begin
            c=c0 ^ {d,8'd0};
            for(k=0;k<8;k=k+1)c=c[15] ? (c<<1)^16'h1021 : c<<1;
            update_crc=c;
        end
    endfunction
    task send_byte(input [7:0] d, input bad_stop);
        integer k;
        begin
            rx=0; repeat(CPB)@(negedge clk);
            for(k=0;k<8;k=k+1)begin rx=d[k];repeat(CPB)@(negedge clk);end
            rx=!bad_stop;repeat(CPB)@(negedge clk);rx=1;
        end
    endtask
    task command(input string s);
        integer k;
        begin for(k=0;k<s.len();k=k+1)send_byte(s[k],0);end
    endtask
    task expect_line(input [1599:0] wanted);
        begin
            wait(nlines>nextline);
            if(lines[nextline]!==wanted) begin
                $display("actual: %0s\nexpected: %0s",lines[nextline],wanted);
                $fatal(1,"upload response mismatch");
            end
            nextline=nextline+1;
        end
    endtask
    task quiet;
        begin
            @(negedge clk);
            while(!dut.serial_quiescent || dut.fsm_busy)@(negedge clk);
            repeat(5)@(negedge clk);
        end
    endtask
    task payload(input integer frame, input corrupt);
        integer k;
        begin
            crc=16'hffff;
            for(k=0;k<576;k=k+1) begin
                send_byte(pixels[frame*576+k],0);
                crc=update_crc(crc,pixels[frame*576+k]);
            end
            if(crc!==golden_crc[frame])$fatal(1,"CRC differs from Python binascii");
            send_byte(crc[15:8],0);send_byte(crc[7:0] ^ corrupt,0);
        end
    endtask
    initial begin
        $readmemh(`VEC("upload_pixels.mem"),pixels);
        $readmemh(`VEC("upload_logits.mem"),logits);
        $readmemh(`VEC("upload_warnings.mem"),warnings);
        $readmemh(`VEC("upload_crc.mem"),golden_crc);
        for(i=0;i<N*576;i=i+1)if(^pixels[i]===1'bx)$fatal(1,"missing upload pixels");
        for(i=0;i<N;i=i+1)if((^logits[i]===1'bx)||(^warnings[i]===1'bx))$fatal(1,"missing upload golden");
        repeat(12)@(negedge clk);btnU=0;repeat(30)@(negedge clk);
        command("LOAD 0000\n");expect_line("ERR MODE");quiet;
        sw[9]=1;repeat(30)@(negedge clk);wait(dut.pc_mode);
        command("LOAD G000\n");expect_line("ERR CMD");quiet;
        command("RUN_FRAME 0000\n");expect_line("ERR NOFRAME");quiet;
        // CRC failure must not launch the CNN or leave a valid old frame.
        command("LOAD 0001\n");expect_line("READY 1");payload(0,1);
        expect_line("ERR CRC");quiet;
        command("RUN_FRAME 0001\n");expect_line("ERR NOFRAME");quiet;
        // Timeout and framing-error tails are drained, including ASCII RUN bytes.
        command("LOAD 0002\n");expect_line("READY 2");send_byte(10,0);
        repeat(10100)@(negedge clk);command("RUN\n");
        expect_line("ERR TIMEOUT");quiet;
        command("LOAD 0003\n");expect_line("READY 3");send_byte(13,1);
        repeat(CPB*2)@(negedge clk);command("RUN\n");expect_line("ERR FRAME");quiet;
        if(starts!=0 || results!=0)$fatal(1,"invalid upload launched CNN");
        // All 16 original images plus non-ROM patterns and temporal sequences.
        for(i=0;i<N;i=i+1) begin
            frameid=16'h1200+i;
            command($sformatf("LOAD %04h\n",frameid));
            $sformat(expected,"READY %0d",16'h1200+i);expect_line(expected);
            payload(i,0);$sformat(expected,"OK FRAME %0d",16'h1200+i);expect_line(expected);quiet;
            if(i==0) begin
                command("RUN_FRAME 1111\n");expect_line("ERR ID");quiet;
            end
            command($sformatf("RUN_FRAME %04h\n",frameid));expect_line("OK RUN");
            if(i==0)begin command("LOAD 9999\n");expect_line("ERR BUSY");end
            l0=logits[i][63:32];l1=logits[i][31:0];
            class_text=(l1>l0)?"OPEN":"CLOSED";
            case(warnings[i])0:warning_text="AWAKE";1:warning_text="DROWSY";2:warning_text="MICROSLEEP";default:$fatal(1,"bad warning");endcase
            $sformat(expected,"RESULT source=UPLOAD slot=0 class=%0s warning=%0s logit0=%0d logit1=%0d cycles=7996 us=79 frame_id=%0d",class_text,warning_text,l0,l1,16'h1200+i);
            expect_line(expected);quiet;
            $display("upload frame %0d: golden logits and temporal state match",i);
            command($sformatf("RUN_FRAME %04h\n",frameid));expect_line("ERR NOFRAME");quiet;
        end
        if(starts!=N || results!=N)$fatal(1,"duplicate/missing inference");
        command($sformatf("LOAD %04h\n",frameid));expect_line("ERR ID");quiet;
        command("LOAD 6000\n");expect_line("READY 24576");payload(0,0);expect_line("OK FRAME 24576");quiet;
        command("LOAD 6001\n");expect_line("READY 24577");payload(0,1);expect_line("ERR CRC");quiet;
        command("RUN_FRAME 6000\n");expect_line("ERR NOFRAME");quiet;
        // The legacy ROM path must still work after upload.
        command("SLOT 0\n");expect_line("OK SLOT 0");quiet;
        command("RUN\n");expect_line("OK RUN");wait(nlines>nextline);
        if(lines[nextline][1599:0] == 0)$fatal(1,"missing ROM result");
        if(dut.logit0!==logits[0][63:32] || dut.logit1!==logits[0][31:0])$fatal(1,"ROM regression after upload");
        nextline=nextline+1;quiet;
        // Reset aborts a partial upload and invalidates its buffer.
        command("LOAD 7000\n");expect_line("READY 28672");send_byte(255,0);
        btnU=1;repeat(12)@(negedge clk);btnU=0;repeat(40)@(negedge clk);
        wait(dut.pc_mode);command("RUN_FRAME 7000\n");expect_line("ERR NOFRAME");quiet;
        // Ownership changes are deferred until the complete upload reply drains.
        command("LOAD 7001\n");expect_line("READY 28673");sw[9]=0;
        repeat(30)@(negedge clk);if(!dut.pc_mode)$fatal(1,"ownership changed during upload");
        payload(0,0);expect_line("OK FRAME 28673");wait(!dut.pc_mode);
        repeat(3)@(negedge clk);
        if(dut.g_uart.u_serial.image_valid)$fatal(1,"image survived board handover");
        $display("PASS tb_uart_upload (37 golden/temporal frames, CRC, timeout/drain, framing, ID, reset, ownership, ROM fallback)");
        $finish;
    end
    initial begin #300000000; $fatal(1,"upload test timeout");end
endmodule
