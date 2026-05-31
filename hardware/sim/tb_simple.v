//=============================================================================
// tb_simple — Verify fft_core_simple against expected values
//=============================================================================

`timescale 1ns / 1ps
`default_nettype none

module tb_simple;

    reg clk, rst_n, start, din_valid;
    reg [31:0] din;
    wire din_ready, busy, frame_done;
    reg [5:0]  tb_rd_addr;
    wire [31:0] tb_rd_data;

    fft_core_simple #(.N_LOG2(6), .WIDTH(16)) uut (
        .clk(clk), .rst_n(rst_n), .start(start),
        .din(din), .din_valid(din_valid), .din_ready(din_ready),
        .busy(busy), .frame_done(frame_done),
        .tb_rd_addr(tb_rd_addr), .tb_rd_data(tb_rd_data)
    );

    always #5 clk = ~clk;

    // Expected values from Python
    reg [31:0] expv [0:63];
    integer i, err, cyc;

    initial begin
        expv[ 0]=32'h000000e0; expv[ 1]=32'hffa9003f; expv[ 2]=32'hfff5fff1; expv[ 3]=32'hffaffffb;
        expv[ 4]=32'h001d0000; expv[ 5]=32'hffd9ffdd; expv[ 6]=32'hfffa0003; expv[ 7]=32'hfff0ffe0;
        expv[ 8]=32'h00210017; expv[ 9]=32'hffeaffcf; expv[10]=32'hfffffffc; expv[11]=32'hffebffcb;
        expv[12]=32'h0006001d; expv[13]=32'h0005fff1; expv[14]=32'hfff8fffa; expv[15]=32'h0015fff2;
        expv[16]=32'h0017002c; expv[17]=32'hffe9ffbb; expv[18]=32'h0005fffc; expv[19]=32'h0002ffcb;
        expv[20]=32'h00000014; expv[21]=32'h000fffd8; expv[22]=32'hfff7fff9; expv[23]=32'h0017ffe2;
        expv[24]=32'hfff90031; expv[25]=32'h000efffb; expv[26]=32'h0001fffd; expv[27]=32'h0015fff1;
        expv[28]=32'hfff00002; expv[29]=32'h000e0002; expv[30]=32'h0007fff7; expv[31]=32'h0011000f;
        expv[32]=32'h00000044; expv[33]=32'hffdfffc9; expv[34]=32'h0007fffb; expv[35]=32'h0003ffd1;
        expv[36]=32'h00010010; expv[37]=32'h0011ffe7; expv[38]=32'hfffcfffd; expv[39]=32'h0010fff2;
        expv[40]=32'hfff90017; expv[41]=32'h0018ffe7; expv[42]=32'h0003fffe; expv[43]=32'h001bffe1;
        expv[44]=32'hfff2000d; expv[45]=32'h000dfffd; expv[46]=32'h0004fff6; expv[47]=32'h0017000a;
        expv[48]=32'hffe9002c; expv[49]=32'h0013fffd; expv[50]=32'hffff0000; expv[51]=32'h00100001;
        expv[52]=32'hfffa0000; expv[53]=32'h000f0004; expv[54]=32'h0003fffb; expv[55]=32'h000d0008;
        expv[56]=32'hffedfffd; expv[57]=32'h00040007; expv[58]=32'h00050001; expv[59]=32'h0009000b;
        expv[60]=32'h0000fff8; expv[61]=32'h00000008; expv[62]=32'h00050005; expv[63]=32'hfff70009;
    end

    initial begin
        clk=0; cyc=0; rst_n=0; start=0; din=0; din_valid=0; tb_rd_addr=0;
        repeat(10) @(posedge clk); rst_n=1; repeat(5) @(posedge clk);

        $display("=== FFT Simple Verification ===");

        // Pulse start
        @(posedge clk); start<=1; @(posedge clk); start<=0;
        while (!din_ready) @(posedge clk);

        // Feed ramp 0..63
        for (i=0; i<64; i=i+1) begin
            din <= {16'd0, i[15:0]};
            din_valid <= 1;
            @(posedge clk);
        end
        din_valid <= 0;
        @(posedge clk);

        $display("64 samples fed. Checking BRAM after S_LOAD:");
        repeat (5) @(posedge clk);
        for (i = 0; i < 8; i = i + 1) begin
            tb_rd_addr <= i[5:0];
            @(posedge clk); @(posedge clk);
            $display("  bram[%0d] = 0x%08x (re=%0d im=%0d)", i, tb_rd_data,
                $signed(tb_rd_data[15:0]), $signed(tb_rd_data[31:16]));
        end

        $display("Waiting for FFT...");

        // Wait for frame_done
        i = 0;
        while (!frame_done && i < 50000) begin @(posedge clk); i=i+1; end
        if (!frame_done) begin $display("TIMEOUT at cyc=%0d", cyc); $finish; end
        $display("FFT done at cyc=%0d (%0d waited)", cyc, i);

        // Read results
        err = 0;
        for (i=0; i<64; i=i+1) begin
            tb_rd_addr <= i[5:0];
            @(posedge clk); @(posedge clk);  // pipeline: addr→r1→data
            if (tb_rd_data !== expv[i]) begin
                $display("FAIL bin%2d: got=0x%08x exp=0x%08x (re=%0d vs %0d, im=%0d vs %0d)",
                    i, tb_rd_data, expv[i],
                    $signed(tb_rd_data[15:0]), $signed(expv[i][15:0]),
                    $signed(tb_rd_data[31:16]), $signed(expv[i][31:16]));
                err = err + 1;
            end
        end

        if (err == 0) $display("\n*** ALL 64 BINS MATCH! ***");
        else $display("\n*** %0d MISMATCHES ***", err);
        $finish;
    end

    always @(posedge clk) cyc <= cyc + 1;

endmodule
