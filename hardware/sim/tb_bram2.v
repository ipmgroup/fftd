`timescale 1ns / 1ps
module tb_bram2;
    reg clk, rst_n, start, din_valid;
    reg [31:0] din;
    wire din_ready;
    reg [5:0] ext_rd_addr;
    wire [31:0] ext_rd_data;
    integer cyc, i, bad;

    fft_core #(.N_LOG2(6), .WIDTH(16)) uut (
        .clk(clk), .rst_n(rst_n), .start(start),
        .din(din), .din_valid(din_valid), .din_ready(din_ready),
        .dout(), .dout_valid(), .busy(), .frame_done(),
        .ext_rd_addr(ext_rd_addr), .ext_rd_data(ext_rd_data)
    );
    always #5 clk=~clk;
    always @(posedge clk) cyc<=cyc+1;

    initial begin
        clk=0; cyc=0; rst_n=0; start=0; din=0; din_valid=0; ext_rd_addr=0;
        repeat(20) @(posedge clk); rst_n=1;
        repeat(10) @(posedge clk);

        @(posedge clk); start<=1; @(posedge clk); start<=0;
        while (!din_ready) @(posedge clk);

        // Load: each address = address value for easy checking
        din_valid<=1;
        for (i=0; i<65; i=i+1) begin  // 65 iterations = 64 writes + 1 extra
            din<={16d0,
