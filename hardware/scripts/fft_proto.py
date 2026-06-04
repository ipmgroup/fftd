#!/usr/bin/env python3
"""
fft_proto.py — FFT readout via SPI protocol (XOR checksum, no CRC)
Usage: python3 fft_proto.py [--raw] [--stats]
"""

import spidev
import sys
import time
import numpy as np

N = 1024
# Hz — reliable readout speed.
#   Dual-clock firmware (SPI domain 87.5 MHz, FFT core 43.75 MHz). Re-measured
#   with the BULK_READ stream: both chunked (0x21) and bulk (0x23) paths are
#   bit-exact up to 14 MHz SCK (0/10 fails). 15 MHz+ starts dropping bits
#   (single-bit errors in the continuous stream; checksum mismatches on STATUS)
#   — the earlier "16 MHz" point was borderline, not solid. 14 MHz is the
#   dependable ceiling given Pi SPI clock quantisation.
#   Single-clock firmware (50 MHz): use 8 MHz here instead.
SPI_SPEED = 14000000

# ── Protocol constants ──────────────────────────
CMD_STATUS_REQ  = 0x60
CMD_FFT_CONFIG  = 0x51
CMD_WRITE_DATA  = 0x41
CMD_READ_RESULT = 0x21
CMD_CONTROL     = 0x50
CMD_SRAM_WRITE  = 0x42
CMD_SRAM_READ   = 0x22
CMD_SRAM_ADDR   = 0x52
CMD_BULK_READ   = 0x23   # stream whole spectrum in one transaction

CTRL_START = 0x01
CTRL_STOP  = 0x02
CTRL_RESET = 0x04


def checksum(cmd, length, seq):
    return cmd ^ length ^ seq


def bit_reverse(idx, bits):
    """Reverse the lower `bits` bits of integer `idx`."""
    result = 0
    for _ in range(bits):
        result = (result << 1) | (idx & 1)
        idx >>= 1
    return result


def bit_reverse_array(samples):
    """Bit-reverse an array for DIT FFT input (N must be power of 2)."""
    N = len(samples)
    bits = N.bit_length() - 1
    if (1 << bits) != N:
        raise ValueError(f"N={N} is not a power of 2")
    result = samples.copy() if hasattr(samples, 'copy') else list(samples)
    for i in range(N):
        j = bit_reverse(i, bits)
        if i < j:
            result[i], result[j] = result[j], result[i]
    return result


class FftProto:
    def __init__(self, bus=0, device=0, speed=SPI_SPEED):
        self.spi = spidev.SpiDev()
        self.spi.open(bus, device)
        self.spi.max_speed_hz = speed
        self.spi.mode = 0
        self.seq = 0

    def close(self):
        self.spi.close()

    def _next_seq(self):
        self.seq = (self.seq + 1) & 0xFF
        return self.seq

    def _xfer_frame(self, cmd, data_out=b'', expected_len=0):
        """Send a protocol frame and read response.

        FPGA states: RX_CMD→RX_LEN→RX_SEQ→RX_CSUM→(RX_DATA)→ST_GAP→TX_CMD→...
        Response starts at MISO byte: 5 + len(data_out)

        Returns (resp_cmd, resp_data, error_message_or_None).
        """
        seq = self._next_seq()
        length = len(data_out)
        csum = checksum(cmd, length, seq)

        # MOSI: header (4) + data + dummy for response (4 header + expected data)
        resp_header = 4
        resp_data_len = expected_len if expected_len > 0 else 1
        dummy_needed = 1 + resp_header + resp_data_len  # +1 for GAP byte
        mosi = bytes([cmd, length, seq, csum]) + data_out + b'\x00' * dummy_needed

        miso = bytes(self.spi.xfer2(list(mosi)))

        # Response starts: 4 (header) + data_len + 1 (GAP)
        resp_start = 4 + length + 1

        if resp_start + 4 > len(miso):
            return None, b'', f"MISO too short: {len(miso)} bytes, need {resp_start + 4}"

        r_cmd  = miso[resp_start]
        r_len  = miso[resp_start + 1]
        r_seq  = miso[resp_start + 2]
        r_csum = miso[resp_start + 3]

        expected_csum = checksum(r_cmd, r_len, r_seq)
        if r_csum != expected_csum:
            return r_cmd, b'', (f"Checksum mismatch: got 0x{r_csum:02x}, "
                                f"expected 0x{expected_csum:02x}")

        r_data = bytes(miso[resp_start + 4 : resp_start + 4 + r_len])
        if len(r_data) < r_len:
            return r_cmd, r_data, f"Response truncated: got {len(r_data)} of {r_len} bytes"

        return r_cmd, r_data, None

    def write_data(self, samples):
        """Write real-only int16 samples to FPGA BRAM (preload)."""
        import time
        MAX_CHUNK = 120  # 240 bytes < 255 LEN limit
        for offset in range(0, len(samples), MAX_CHUNK):
            chunk = samples[offset:offset+MAX_CHUNK]
            data_out = b''
            for s in chunk:
                v = int(s) & 0xFFFF
                data_out += bytes([(v >> 8) & 0xFF, v & 0xFF])
            _, _, err = self._xfer_frame(CMD_WRITE_DATA, data_out)
            if err:
                return err
            time.sleep(0.01)  # 10ms gap — let FPGA settle
        return None

    def write_data_bitrev(self, samples):
        """Bit-reverse samples then write to FPGA BRAM (for DIT FFT)."""
        bitrev_samples = bit_reverse_array(samples)
        return self.write_data(bitrev_samples)

    def status(self):
        """Read STATUS register."""
        cmd, data, err = self._xfer_frame(CMD_STATUS_REQ, b'', expected_len=1)
        if err:
            return None, err
        if len(data) < 1:
            return None, "No status byte"
        status = data[0]
        flags = {
            'ready':     bool(status & 0x80),
            'busy':      bool(status & 0x40),
            'done':      bool(status & 0x20),
            'error':     bool(status & 0x10),
            'exp':       status & 0x0F,   # BFP exponent (true value = out << exp)
        }
        return flags, None

    def control(self, code):
        """Send CONTROL command (START/STOP/RESET)."""
        cmd, data, err = self._xfer_frame(CMD_CONTROL, bytes([code]))
        return err

    # Max bins per frame: 4 bytes/bin and LEN is 8-bit (255) → 63.
    MAX_BINS_PER_FRAME = 63

    def read_result(self, num_bins=60):
        """Read FFT result bins (complex, 4 bytes/bin: re_hi,re_lo,im_hi,im_lo).

        Returns raw int16 complex values (still scaled by the BFP exponent).
        """
        if num_bins > self.MAX_BINS_PER_FRAME:
            num_bins = self.MAX_BINS_PER_FRAME
        cmd, data, err = self._xfer_frame(
            CMD_READ_RESULT,
            bytes([num_bins]),
            expected_len=num_bins * 4
        )
        if err:
            return None, err
        if len(data) < num_bins * 4:
            return None, f"Got {len(data)} bytes, expected {num_bins * 4}"

        bins = np.zeros(num_bins, dtype=complex)
        for i in range(num_bins):
            re = (data[i * 4] << 8) | data[i * 4 + 1]
            im = (data[i * 4 + 2] << 8) | data[i * 4 + 3]
            if re & 0x8000:
                re -= 0x10000
            if im & 0x8000:
                im -= 0x10000
            bins[i] = complex(re, im)
        return bins, None

    def read_all_bins(self, total=1024, chunk=60, rescale=True, hermitian=False):
        """Read FFT bins in chunks. Returns true complex FFT values.

        With rescale=True the raw int16 bins are multiplied by 2**bfp_exp
        (read from STATUS) so the result matches numpy.fft.fft(int_samples).

        With hermitian=True (valid only for real input) only the unique
        N/2+1 bins are read over SPI and the upper half is reconstructed via
        conjugate symmetry X[N-k] = conj(X[k]) — roughly halves readout time.
        """
        if chunk > self.MAX_BINS_PER_FRAME:
            chunk = self.MAX_BINS_PER_FRAME
        scale = 1.0
        if rescale:
            flags, err = self.status()
            if not err:
                scale = float(1 << flags['exp'])

        n_read = (total // 2 + 1) if hermitian else total
        bins_read = np.zeros(n_read, dtype=complex)
        for offset in range(0, n_read, chunk):
            n = min(chunk, n_read - offset)
            bins, err = self.read_result(n)
            if err:
                return None, f"Chunk {offset}: {err}"
            bins_read[offset:offset+n] = bins

        if hermitian:
            all_bins = np.zeros(total, dtype=complex)
            all_bins[:n_read] = bins_read
            # X[N-k] = conj(X[k]) for k = 1 .. N/2-1
            all_bins[n_read:] = np.conj(bins_read[1:total - n_read + 1][::-1])
            return all_bins * scale, None
        return bins_read * scale, None

    def bulk_read(self, n_bins, rescale=True, hermitian=False):
        """Stream `n_bins` complex bins in ONE SPI transaction (BULK_READ 0x23).

        Removes the per-frame overhead of the chunked read path: the FPGA keeps
        emitting 4-byte bins (re_hi,re_lo,im_hi,im_lo) for as long as CS stays
        asserted, starting from bin 0. The master simply clocks the exact byte
        count it wants, then deasserts CS.

        Returns true complex FFT values (rescaled by 2**bfp_exp when rescale).

        Note: spidev's default transfer buffer is 4096 bytes. One transaction
        carries 9 header bytes + n_bins*4 data bytes, so n_bins is capped near
        ~1021 unless the spidev bufsiz module param is raised. Hermitian
        (n_bins = N/2+1) stays well under the limit.
        """
        scale = 1.0
        if rescale:
            flags, err = self.status()
            if not err:
                scale = float(1 << flags['exp'])

        n_read = (n_bins // 2 + 1) if hermitian else n_bins

        seq  = self._next_seq()
        csum = checksum(CMD_BULK_READ, 0, seq)
        # header(4) + GAP(1) + TX header(4) = 9 bytes before the stream begins.
        data_off = 9
        mosi = bytes([CMD_BULK_READ, 0, seq, csum]) + b'\x00' * (data_off - 4 + n_read * 4)

        miso = bytes(self.spi.xfer2(list(mosi)))
        if len(miso) < data_off + n_read * 4:
            return None, f"MISO too short: {len(miso)}, need {data_off + n_read * 4}"

        payload = miso[data_off:data_off + n_read * 4]
        bins = np.zeros(n_read, dtype=complex)
        for i in range(n_read):
            re = (payload[i * 4] << 8) | payload[i * 4 + 1]
            im = (payload[i * 4 + 2] << 8) | payload[i * 4 + 3]
            if re & 0x8000:
                re -= 0x10000
            if im & 0x8000:
                im -= 0x10000
            bins[i] = complex(re, im)

        if hermitian:
            all_bins = np.zeros(n_bins, dtype=complex)
            all_bins[:n_read] = bins
            all_bins[n_read:] = np.conj(bins[1:n_bins - n_read + 1][::-1])
            return all_bins * scale, None
        return bins * scale, None

    def wait_done(self, timeout=2.0, poll_ms=50):
        """Poll STATUS until done=1 or timeout."""
        t0 = time.time()
        while time.time() - t0 < timeout:
            flags, err = self.status()
            if err:
                print(f"  Status error: {err}")
                time.sleep(poll_ms / 1000)
                continue
            if flags['done']:
                return True
            if flags['error']:
                return False
            time.sleep(poll_ms / 1000)
        return False

    # ── SRAM Debug Commands ──────────────────────

    def sram_set_addr(self, addr):
        """Set SRAM byte-address pointer (19-bit)."""
        data = bytes([(addr >> 16) & 0x07, (addr >> 8) & 0xFF, addr & 0xFF])
        _, _, err = self._xfer_frame(CMD_SRAM_ADDR, data)
        return err

    def sram_write(self, word32):
        """Write 32-bit word to SRAM at current pointer, auto-increment."""
        data = bytes([(word32 >> 24) & 0xFF, (word32 >> 16) & 0xFF,
                       (word32 >> 8) & 0xFF, word32 & 0xFF])
        _, _, err = self._xfer_frame(CMD_SRAM_WRITE, data)
        return err

    def sram_read(self):
        """Read 32-bit word from SRAM at current pointer, auto-increment."""
        cmd, data, err = self._xfer_frame(CMD_SRAM_READ, b'', expected_len=4)
        if err:
            return None, err
        if len(data) < 4:
            return None, f"Got {len(data)} bytes, expected 4"
        return (data[0] << 24) | (data[1] << 16) | (data[2] << 8) | data[3], None

    def sram_test(self, addr=0, pattern=0xA5A55A5A):
        """Quick SRAM test: write pattern, read back, verify."""
        err = self.sram_set_addr(addr)
        if err: return f"ADDR err: {err}"
        err = self.sram_write(pattern)
        if err: return f"WRITE err: {err}"
        val, err = self.sram_read()
        if err: return f"READ err: {err}"
        if val != pattern:
            return f"MISMATCH: wrote 0x{pattern:08X}, got 0x{val:08X}"
        return None  # OK


def main():
    raw_mode = "--raw" in sys.argv
    stats_mode = "--stats" in sys.argv

    proto = FftProto()

    # ── Status check ─────────────────────────────
    flags, err = proto.status()
    if err:
        print(f"STATUS error: {err}")
        proto.close()
        sys.exit(1)
    print(f"STATUS: ready={flags['ready']} busy={flags['busy']} "
          f"done={flags['done']} error={flags['error']}")

    # ── Start FFT ────────────────────────────────
    print("Starting FFT...")
    err = proto.control(CTRL_START)
    if err:
        print(f"CONTROL error: {err}")

    # ── Wait for done ────────────────────────────
    print("Waiting for FFT completion...")
    ok = proto.wait_done(timeout=5.0)
    if not ok:
        print("FFT did not complete!")
        proto.close()
        sys.exit(1)
    print("FFT done!")

    # ── Read result ──────────────────────────────
    print(f"Reading {N} bins in chunks...")
    bins, err = proto.read_all_bins(N)
    if err:
        print(f"READ_RESULT error: {err}")
        proto.close()
        sys.exit(1)

    # ── Reference ────────────────────────────────
    ramp = np.arange(N, dtype=np.float64)
    ref = np.fft.fft(ramp)
    mag_ref = np.abs(ref)
    mag_fpga = np.abs(bins)

    if not raw_mode:
        print(f"\n{'Bin':>4s}  {'FPGA_real':>10s}  {'FPGA_imag':>10s}  "
              f"{'FPGA_mag':>10s}  {'NumPy_mag':>10s}")
        print("-" * 58)
        for i in range(N):
            print(f"{i:4d}  {bins[i].real:10.4f}  {bins[i].imag:10.4f}  "
                  f"{mag_fpga[i]:10.4f}  {mag_ref[i]:10.2f}")
    else:
        for i in range(N):
            print(f"{bins[i].real:.6f} {bins[i].imag:.6f}")

    fpga_max = np.max(mag_fpga)
    print(f"\nFPGA max |X|: {fpga_max:.4f}   NumPy max |X|: {np.max(mag_ref):.2f}")

    if stats_mode:
        # Correlation check
        corr = np.corrcoef(mag_fpga, mag_ref)[0, 1]
        print(f"Correlation FPGA vs NumPy: {corr:.6f}")

    proto.close()


if __name__ == '__main__':
    main()
