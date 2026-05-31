// tb_bram_test — verify BRAM write/read directly
`timescale 1ns / 1ps
`default_nettype none
module tb_bram_test;
    reg clk, rst_n, start, din_valid;
    reg [31:0] din;
    wire din_ready, busy, frame_done;
    reg [5:0] ext_rd_addr;
    wire [31:0] ext_rd_data;
    integer cyc, i;

    fft_core #(.N_LOG2(6), .WIDTH(16)) uut (
        .clk(clk), .rst_n(rst_n), .start(start),
        .din(din), .din_valid(din_valid), .din_ready(din_ready),
        .dout(), .dout_valid(), .busy(busy), .frame_done(frame_done),
        .ext_rd_addr(ext_rd_addr), .ext_rd_data(ext_rd_data)
    );
    always #5 clk=~clk;
    always @(posedge clk) cyc<=cyc+1;

    initial begin
        clk=0; cyc=0; rst_n=0; start=0; din=0; din_valid=0; ext_rd_addr=0;
        repeat(20) @(posedge clk); rst_n=1;
        repeat(10) @(posedge clk);
        $display("=== BRAM Write/Read Test | Cycle %0d ===", cyc);

        // Pulse start
        @(posedge clk); start<=1; @(posedge clk); start<=0;
        while (!din_ready) @(posedge clk);

        // Extra cycle to let FSM settle in S_LOAD
        @(posedge clk);
        // Load 64 values
        din_valid<=1;
        for (i=0; i<64; i=i+1) begin
            din<={16'h0000, 16'hAAAA + i[15:0]};
            @(posedge clk);
        end
        din_valid<=0;
        $display("Cycle %0d: loaded 64 values, busy=%b", cyc, busy);

        // Wait a few cycles for writes to settle
        repeat(5) @(posedge clk);

        // Read BRAM immediately (before FFT passes)
        $display("Reading BRAM at cycle %0d:", cyc);
        for (i=0; i<64; i=i+1) begin
            ext_rd_addr<=i[5:0];
            repeat(3) @(posedge clk);
            $display("  addr %2d = 0x%08x  (re=%0d im=%0d)",
                i, ext_rd_data,
                $signed(ext_rd_data[15:0]),
                $signed(ext_rd_data[31:16]));
        end

        $finish;
    end
endmodule
