`timescale 1ns / 1ps
module tw_debug;
    reg clk;
    reg [5:0] addr;
    wire [31:0] dout;

    twiddle_rom #(.N(64), .WIDTH(16)) tw (.clk(clk), .addr(addr), .dout(dout));

    always #5 clk = ~clk;

    initial begin
        clk = 0; addr = 0;
        $display("twiddle_rom test");
        repeat (3) @(posedge clk);
        $display("addr=0: dout=0x%08x (re=0x%04x im=0x%04x)", dout, dout[15:0], dout[31:16]);
        addr = 1; repeat (3) @(posedge clk);
        $display("addr=1: dout=0x%08x (re=0x%04x im=0x%04x)", dout, dout[15:0], dout[31:16]);
        addr = 2; repeat (3) @(posedge clk);
        $display("addr=2: dout=0x%08x (re=0x%04x im=0x%04x)", dout, dout[15:0], dout[31:16]);
        $finish;
    end
endmodule
