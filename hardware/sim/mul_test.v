`timescale 1ns / 1ps
module mul_test;
    reg signed [15:0] a, b;
    reg signed [31:0] o;
    reg clk;
    always #5 clk = ~clk;
    always @(posedge clk) o <= a * b;
    initial begin
        clk = 0; a = 0; b = 0;
        #10 a = 10; b = 20;
        #10 $display("10*20 = %0d (0x%08x)", o, o);
        a = -10; b = 20;
        #10 $display("-10*20 = %0d (0x%08x)", o, o);
        a = 32767; b = 32767;
        #10 $display("32767*32767 = %0d (0x%08x)", o, o);
        $finish;
    end
endmodule
