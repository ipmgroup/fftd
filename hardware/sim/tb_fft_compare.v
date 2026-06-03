//=============================================================================
// tb_fft_compare — FFT co-simulation testbench
//
// Reads 64 complex samples from fft_input.hex  {imag[15:0], real[15:0]}
// Runs fft_core, writes 64 output bins to fft_output.hex (same format)
// Used by compare_fft.py to verify against numpy.fft.fft()
//=============================================================================
`timescale 1ns / 1ps
`default_nettype none

module tb_fft_compare;

    localparam N      = 1024;
    localparam N_LOG2 = 10;

    reg        clk, rst_n, start, din_valid;
    reg [31:0] din;
    wire       din_ready, dout_valid, busy, frame_done;
    wire [31:0] dout;
    reg  [N_LOG2-1:0] ext_rd_addr;
    wire [31:0]       ext_rd_data;
    wire [3:0]        bfp_exp;

    reg  [31:0] samples [0:N-1];
    reg  [31:0] results [0:N-1];
    integer i, fd, timeout_cnt;

    fft_core #(.N_LOG2(N_LOG2), .WIDTH(16)) uut (
        .clk         (clk),
        .rst_n       (rst_n),
        .start       (start),
        .din         (din),
        .din_valid   (din_valid),
        .din_ready   (din_ready),
        .dout        (dout),
        .dout_valid  (dout_valid),
        .busy        (busy),
        .frame_done  (frame_done),
        .ext_rd_addr (ext_rd_addr),
        .ext_rd_data (ext_rd_data),
        .bfp_exp     (bfp_exp)
    );

    always #5 clk = ~clk;

    initial begin
        $readmemh("fft_input.hex", samples);

        clk=0; rst_n=0; start=0; din=0; din_valid=0; ext_rd_addr=0;
        repeat(20) @(posedge clk); rst_n=1;
        repeat(10) @(posedge clk);

        // start pulse
        @(posedge clk); start<=1;
        @(posedge clk); start<=0;
        while (!din_ready) @(posedge clk);

        // feed samples
        din_valid<=1;
        for (i=0; i<N; i=i+1) begin
            din <= samples[i];
            @(posedge clk);
        end
        din_valid<=0;

        // wait for FFT done
        timeout_cnt=0;
        while (!frame_done && timeout_cnt<200000) begin
            @(posedge clk); timeout_cnt=timeout_cnt+1;
        end
        if (!frame_done) begin
            $display("ERROR: FFT timeout");
            $finish;
        end

        // read results via ext_rd_addr (2-cycle pipeline:
        // addr→bram_rd_a→rd_a→ext_rd_data). Wait 3 edges before sampling.
        @(posedge clk);
        for (i=0; i<N; i=i+1) begin
            ext_rd_addr <= i[N_LOG2-1:0];
            @(posedge clk);
            @(posedge clk);
            @(posedge clk);
            results[i] = ext_rd_data;
        end

        // write output hex file
        fd = $fopen("fft_output.hex", "w");
        if (fd == 0) begin
            $display("ERROR: cannot open fft_output.hex");
            $finish;
        end
        for (i=0; i<N; i=i+1)
            $fwrite(fd, "%08x\n", results[i]);
        $fclose(fd);

        // Write BFP exponent for the comparator to rescale the reference.
        fd = $fopen("fft_exp.txt", "w");
        $fwrite(fd, "%0d\n", bfp_exp);
        $fclose(fd);

        $display("OK: fft_output.hex written (%0d bins), bfp_exp=%0d", N, bfp_exp);
        $finish;
    end

endmodule
`default_nettype wire
