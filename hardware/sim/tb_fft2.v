`timescale 1ns / 1ps
module tb_fft2;
    reg clk,rst_n,start,din_valid; reg [31:0] din;
    wire din_ready,busy,frame_done;
    reg [5:0] ext_rd_addr; wire [31:0] ext_rd_data;
    integer cyc,i,err; reg [31:0] out[0:63];

    fft_core #(.N_LOG2(6),.WIDTH(16)) uut(
        .clk(clk),.rst_n(rst_n),.start(start),
        .din(din),.din_valid(din_valid),.din_ready(din_ready),
        .dout(),.dout_valid(),.busy(busy),.frame_done(frame_done),
        .ext_rd_addr(ext_rd_addr),.ext_rd_data(ext_rd_data)
    );
    always #5 clk=~clk; always @(posedge clk) cyc<=cyc+1;

    initial begin
        clk=0;cyc=0;rst_n=0;start=0;din=0;din_valid=0;ext_rd_addr=0;
        repeat(20) @(posedge clk); rst_n=1; repeat(10) @(posedge clk);

        // start pulse
        @(posedge clk); start<=1; @(posedge clk); start<=0;
        while(!din_ready) @(posedge clk);

        // Feed exactly 64 values with careful timing
        din_valid<=1; din<=0;
        for(i=0;i<64;i=i+1) begin
            @(posedge clk);
            din<={16d0, i[15:0]};
        end
        din_valid<=0; @(posedge clk); // flush

        i=0; while(!frame_done && i<5000) begin @(posedge clk); i=i+1; end
        if(!frame_done) begin $display("TIMEOUT"); $finish; end
        $display("FFT done at cyc=%0d",cyc);

        // Read
        @(posedge clk);
        for(i=0;i<64;i=i+1) begin ext_rd_addr<=i[5:0]; repeat(3) @(posedge clk); out[i]=ext_rd_data; end

        err=0;
        for(i=0;i<64;i=i+1) if(out[i]===32bx) begin $display("X at %0d",i); err=err+1; end
        if(err==0) begin
            $display("ALL VALID");
            $display("DC=%0d",$signed(out[0][15:0]));
        end else $display("%0d X values",err);
        $finish;
    end
endmodule
