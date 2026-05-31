`timescale 1ns / 1ps
module tb_fft_verify;
    reg clk, rst_n, start, din_valid;
    reg [31:0] din;
    wire din_ready, busy, frame_done;
    reg [4:0] ext_rd_addr;  // N_LOG2=5
    wire [31:0] ext_rd_data;
    integer i;

    fft_core #(.N_LOG2(5), .WIDTH(16)) uut (
        .clk(clk), .rst_n(rst_n), .start(start),
        .din(din), .din_valid(din_valid), .din_ready(din_ready),
        .dout(), .dout_valid(), .busy(busy), .frame_done(frame_done),
        .ext_rd_addr(ext_rd_addr), .ext_rd_data(ext_rd_data)
    );
    always #5 clk = ~clk;

    reg [5:0] d_cnt;
    reg [4:0] feed_val;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin d_cnt<=0; din_valid<=0; feed_val<=0; end
        else if (d_cnt < 32) begin din_valid <= 1; if (din_ready) begin d_cnt<=d_cnt+1; feed_val<=feed_val+1; end
        end else din_valid <= 0;
    end
    assign din = {16'd0, feed_val};

    initial begin
        clk=0; rst_n=0; start=0; ext_rd_addr=0;
        repeat(20) @(posedge clk); rst_n=1; repeat(5) @(posedge clk);
        start=1;
        i=0; while(!frame_done && i<50000) begin @(posedge clk); i=i+1; end
        $display("FFT done in %0d cycles", i);
        @(posedge clk);
        $display("BRAM_DUMP");
        for(i=0; i<32; i=i+1) begin
            ext_rd_addr<=i[4:0]; @(posedge clk); @(posedge clk);
            $display("%0d %0d", $signed(ext_rd_data[15:0]), $signed(ext_rd_data[31:16]));
        end
        $finish;
    end
endmodule
