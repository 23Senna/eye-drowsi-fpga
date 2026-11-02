// image_rom.v - 16 slots x 1024 words (24x24 = 576 pixels + zero pad), uint8.
// addr = {slot[3:0], pix[9:0]}, pix = row*24 + col. 1-cycle registered read (4 x BRAM36).
module image_rom #(
    parameter MEM_FILE = "images.mem"
) (
    input  wire        clk,
    input  wire [13:0] addr,
    output reg  [7:0]  data
);
    reg [7:0] mem [0:16383];
    initial $readmemh(MEM_FILE, mem);
    always @(posedge clk) data <= mem[addr];
endmodule
