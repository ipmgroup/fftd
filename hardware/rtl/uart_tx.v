// uart_tx — Simple UART transmitter for FFT results
// 115200 bps @ 100 MHz: 868 clocks/bit
// Format: 64 lines of "bin: real imag\n"
`default_nettype none
module uart_tx(
    input clk, input rst_n,
    input send,                  // pulse to start sending 64 samples
    input [31:0] din,            // {imag[15:0], real[15:0]}
    input din_valid,             // valid each cycle during unload
    output reg tx                // UART TX pin
);
    // Baud: 100_000_000 / 115200 = 868.055... ≈ 868
    localparam BAUD_DIV = 868;
    // States
    localparam S_IDLE=0, S_BYTE=1, S_STOP=2;
    reg [1:0] state;
    reg [10:0] baud_cnt;
    reg [3:0]  bit_idx;
    reg [7:0]  tx_byte;
    reg [5:0]  sample_cnt;  // 0..63
    reg [2:0]  byte_phase;  // 0=bin_low, 1=bin_hi, 2=sp, 3=re_low, 4=re_hi, 5=nl, 6=cr
    reg [15:0] sample_re, sample_im;
    reg [5:0]  bin;
    reg        sending;
    reg        captured;
    reg [31:0] capture_reg;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state<=S_IDLE; baud_cnt<=0; bit_idx<=0; tx<=1;
            sample_cnt<=0; byte_phase<=0; sending<=0; captured<=0;
            bin<=0; sample_re<=0; sample_im<=0; capture_reg<=0; tx_byte<=0;
        end else begin
            // Start sending when send is pulsed
            if (send && !sending) begin
                sending <= 1;
                sample_cnt <= 0;
                byte_phase <= 0;
                bin <= 0;
            end

            // Capture FFT output
            if (din_valid && sending) begin
                capture_reg <= din;
                captured <= 1;
                bin <= bin + 1;
            end

            // UART byte transmitter
            case (state)
                S_IDLE: begin
                    tx <= 1;  // idle high
                    if (captured && sending) begin
                        // Prepare next byte
                        sample_im <= capture_reg[31:16];
                        sample_re <= capture_reg[15:0];
                        captured <= 0;
                        case (byte_phase)
                            0: tx_byte <= capture_reg[7:0];     // real low byte
                            1: tx_byte <= capture_reg[15:8];    // real high byte
                            2: tx_byte <= 8'h20;                // space
                            3: tx_byte <= capture_reg[23:16];   // imag low byte
                            4: tx_byte <= capture_reg[31:24];   // imag high byte
                            5: tx_byte <= 8'h0A;                // newline
                            default: tx_byte <= 8'h00;
                        endcase
                        state <= S_BYTE;
                        bit_idx <= 0;
                        baud_cnt <= 0;
                        tx <= 0;  // start bit
                    end
                end

                S_BYTE: begin
                    if (baud_cnt == BAUD_DIV-1) begin
                        baud_cnt <= 0;
                        bit_idx <= bit_idx + 1;
                        if (bit_idx == 8) begin
                            tx <= 1;  // stop bit
                            state <= S_STOP;
                        end else begin
                            tx <= tx_byte[bit_idx];
                        end
                    end else begin
                        baud_cnt <= baud_cnt + 1;
                    end
                end

                S_STOP: begin
                    if (baud_cnt == BAUD_DIV-1) begin
                        baud_cnt <= 0;
                        state <= S_IDLE;
                        // Next byte phase
                        if (byte_phase == 5) begin
                            byte_phase <= 0;
                            sample_cnt <= sample_cnt + 1;
                            if (sample_cnt == 63) begin
                                sending <= 0;
                            end
                        end else begin
                            byte_phase <= byte_phase + 1;
                        end
                    end else begin
                        baud_cnt <= baud_cnt + 1;
                    end
                end
            endcase
        end
    end
endmodule
`default_nettype wire
