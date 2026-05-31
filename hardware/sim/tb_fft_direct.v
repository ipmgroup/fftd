// tb_fft_direct — Test FFT with preloaded BRAM (bypass S_LOAD)
`timescale 1ns / 1ps
module tb_fft_direct;
    reg clk, rst_n, start, din_valid;
    reg [31:0] din;
    wire din_ready, busy, frame_done;
    reg [5:0] ext_rd_addr;
    wire [31:0] ext_rd_data;
    integer cyc, i, errors;
    reg [31:0] actual [0:63];

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
        repeat(20) @(posedge clk);

        $display("=== FFT Direct Test (BRAM preloaded) | Cycle %0d ===", cyc);

        // Pulse start — but DON'T feed data; BRAM is already initialized
        @(posedge clk); start<=1;
        @(posedge clk); start<=0;

        // FFT should go S_IDLE → S_LOAD but din_valid=0 so it skips writes,
        // then transitions to S_BF_RD immediately? No — S_LOAD checks din_valid.
        // Without din_valid, idx stays 0 and we're stuck in S_LOAD forever!

        // Hmm, the FSM expects data. Let me feed dummy data (zeros) for 64 cycles.
        while (!din_ready) @(posedge clk);
        @(posedge clk);
        din_valid<=1;
        for (i=0; i<64; i=i+1) begin
            din<=32'h00000000;  // zeros — BRAM already has real data
            @(posedge clk);
        end
        din_valid<=0;
        $display("Cycle %0d: fed zeros, busy=%b", cyc, busy);

        // Wait for FFT completion
        i=0; while (!frame_done && i<5000) begin @(posedge clk); i=i+1; end
        if (!frame_done) begin $display("TIMEOUT"); $finish; end
        $display("Cycle %0d: FFT done!", cyc);

        // Read results
        @(posedge clk);
        for (i=0; i<64; i=i+1) begin
            ext_rd_addr<=i[5:0]; repeat(3) @(posedge clk);
            actual[i]=ext_rd_data;
        end

        $display("\nFFT results:");
        for (i=0; i<64; i=i+1)
            $display("  bin%2d: re=%6d im=%6d  %04x_%04x", i,
                $signed(actual[i][15:0]), $signed(actual[i][31:16]),
                actual[i][31:16], actual[i][15:0]);

        // Checks
        errors=0;
        for (i=0; i<64; i=i+1) if (actual[i]===32'bx) begin
            $display("FAIL: bin%0d X", i); errors=errors+1; end
        if (errors==0) $display("PASS: all valid");
        if ($signed(actual[0][15:0])!=0) $display("PASS: DC=%0d", $signed(actual[0][15:0]));
        else begin $display("FAIL: DC=0"); errors=errors+1; end
        for (i=1; i<32; i=i+1)
            if ($signed(actual[i][15:0])!==$signed(actual[64-i][15:0])) begin
                $display("FAIL: re[%0d]!=re[%0d]", i, 64-i); errors=errors+1; end
        if (errors==0) $display("\n*** ALL CHECKS PASSED ***");
        else $display("\n*** %0d ERRORS ***", errors);
        $finish;
    end
endmodule
