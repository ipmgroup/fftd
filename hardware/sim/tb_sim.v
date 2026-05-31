`timescale 1ns / 1ps
module tb_sim;
    reg clk, rst_n, start;
    reg [5:0] ext_rd_addr;
    wire [31:0] ext_rd_data;
    wire frame_done;
    integer i, cyc;

    fft_core #(.N_LOG2(6), .WIDTH(16)) uut (
        .clk(clk), .rst_n(rst_n), .start(start),
        .din(0), .din_valid(0), .din_ready(), .dout(), .dout_valid(),
        .busy(), .frame_done(frame_done),
        .ext_rd_addr(ext_rd_addr), .ext_rd_data(ext_rd_data)
    );
    always #5 clk=~clk;
    always @(posedge clk) cyc<=cyc+1;

    initial begin
        clk=0; cyc=0; rst_n=0; start=0; ext_rd_addr=0;
        repeat(20) @(posedge clk); rst_n=1; repeat(5) @(posedge clk);

        // Skip S_LOAD — must modify fft_core temporarily
        // For now, just run with $readmemh
        start=1;
        i=0; while(!frame_done && i<20000) begin @(posedge clk); i=i+1; end
        if(!frame_done) begin $display("TIMEOUT"); $finish; end
        $display("FFT done at cyc=%0d", cyc);

        @(posedge clk);
        for(i=0; i<8; i=i+1) begin
            ext_rd_addr<=i[5:0]; @(posedge clk); @(posedge clk);
            $display("bin%2d: 0x%08x (re=%0d im=%0d)", i,
                ext_rd_data, $signed(ext_rd_data[15:0]), $signed(ext_rd_data[31:16]));
        end
        $finish;
    end
endmodule
