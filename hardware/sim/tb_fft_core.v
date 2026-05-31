//=============================================================================
// tb_fft_core — Minimal FFT core test with state monitoring
//=============================================================================

`timescale 1ns / 1ps
`default_nettype none

module tb_fft_core;

    reg        clk, rst_n, start, din_valid;
    reg [31:0] din;
    wire       din_ready, dout_valid, busy, frame_done;
    wire [31:0] dout;
    reg [5:0]  ext_rd_addr;
    wire [31:0] ext_rd_data;
    integer    cyc, i, errors;
    reg [31:0] actual [0:63];

    fft_core #(.N_LOG2(6), .WIDTH(16)) uut (
        .clk(clk), .rst_n(rst_n), .start(start),
        .din(din), .din_valid(din_valid), .din_ready(din_ready),
        .dout(dout), .dout_valid(dout_valid),
        .busy(busy), .frame_done(frame_done),
        .ext_rd_addr(ext_rd_addr), .ext_rd_data(ext_rd_data)
    );

    always #5 clk = ~clk;
    always @(posedge clk) cyc <= cyc + 1;

    initial begin
        clk=0; cyc=0; rst_n=0; start=0; din=0; din_valid=0; ext_rd_addr=0;
        repeat (20) @(posedge clk); rst_n=1;
        repeat (10) @(posedge clk);
        $display("=== FFT Core Test | Cycle %0d ===", cyc);

        // Pulse start
        @(posedge clk); start<=1;
        @(posedge clk); start<=0;
        while (!din_ready) @(posedge clk);
        $display("Cycle %0d: din_ready, feeding 64 samples", cyc);

        din_valid<=1;
        for (i=0; i<64; i=i+1) begin
            din<={16'd0, i[15:0]};
            @(posedge clk);
        end
        din_valid<=0;
        $display("Cycle %0d: loaded, busy=%b", cyc, busy);

        i=0;
        while (!frame_done && i<5000) begin @(posedge clk); i=i+1; end
        if (!frame_done) begin
            $display("TIMEOUT at cyc=%0d busy=%b done=%b", cyc, busy, frame_done);
            $finish;
        end
        $display("Cycle %0d: FFT done!", cyc);

        // Read BRAM
        @(posedge clk);
        for (i=0; i<64; i=i+1) begin
            ext_rd_addr<=i[5:0]; @(posedge clk); @(posedge clk);
            actual[i]=ext_rd_data;
        end

        // Print & check
        $display("\nBin  re        im          hex");
        for (i=0; i<64; i=i+1)
            $display("%2d: %8d %8d   %04x_%04x", i,
                $signed(actual[i][15:0]), $signed(actual[i][31:16]),
                actual[i][31:16], actual[i][15:0]);

        errors=0;
        for (i=0; i<64; i=i+1) if (actual[i]===32'bx) begin
            $display("FAIL: bin %0d is X", i); errors=errors+1; end
        if (errors==0) $display("PASS: all valid");
        if ($signed(actual[0][15:0])!=0) $display("PASS: DC=%0d", $signed(actual[0][15:0]));
        else begin $display("FAIL: DC=0"); errors=errors+1; end
        if (errors==0) $display("\n*** ALL CHECKS PASSED ***");
        else $display("\n*** %0d ERRORS ***", errors);
        $finish;
    end
endmodule
