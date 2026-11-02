`timescale 1ns/1ps
`include "tb_paths.vh"
// tb_roms.v - 1-cycle registered read and addressing of image_rom and weight_bias_rom.
module tb_roms;
    reg clk = 0; reg [13:0] ia = 0; reg [11:0] wa = 0; reg [4:0] ba = 0;
    wire [7:0] id, wd; wire [31:0] bd;
    reg [7:0] img [0:16383]; reg [7:0] w [0:579]; reg [31:0] b [0:13];
    integer i, errors = 0;
    image_rom #(.MEM_FILE(`MEM("images.mem"))) u_img (.clk(clk), .addr(ia), .data(id));
    weight_bias_rom #(.W_FILE(`MEM("weights.mem")), .B_FILE(`MEM("biases.mem"))) u_wb (
        .clk(clk), .w_addr(wa), .w_data(wd), .b_addr(ba), .b_data(bd));
    always #5 clk = ~clk;
    initial begin
        $readmemh(`MEM("images.mem"), img); $readmemh(`MEM("weights.mem"), w); $readmemh(`MEM("biases.mem"), b);
        for (i = 0; i < 16384; i = i + 1) begin
            @(negedge clk) ia = i; wa = i % 580; ba = i % 14;
            @(posedge clk) #1;
            if (id !== img[i] || wd !== w[i % 580] || bd !== b[i % 14]) begin
                errors = errors + 1; if (errors < 5) $display("FAIL addr %0d: %h %h %h", i, id, wd, bd);
            end
        end
        // registered: data must not change before the clock edge
        @(negedge clk) ia = 11'd5; #2 if (id !== img[16383]) begin errors = errors + 1; $display("FAIL: not registered"); end
        if (errors == 0) $display("PASS tb_roms"); else $display("FAIL tb_roms: %0d errors", errors);
        $finish;
    end
endmodule
