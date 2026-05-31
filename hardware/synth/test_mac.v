module test_mac(input clk, input [15:0] a, b, output reg [31:0] acc);
    reg [15:0] ar, br;
    always @(posedge clk) begin
        ar <= a; br <= b;
        acc <= ar * br + acc;
    end
endmodule
