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
SPI_SPEED = 10000000  # Hz — max reliable at 50 MHz sysclk (5× oversampling)

# ── Protocol constants ──────────────────────────
CMD_STATUS_REQ  = 0x60
CMD_FFT_CONFIG  = 0x51
CMD_WRITE_DATA  = 0x41
CMD_READ_RESULT = 0x21
CMD_CONTROL     = 0x50

CTRL_START = 0x01
CTRL_STOP  = 0x02
CTRL_RESET = 0x04


def checksum(cmd, length, seq):
    return cmd ^ length ^ seq


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
        }
        return flags, None

    def control(self, code):
        """Send CONTROL command (START/STOP/RESET)."""
        cmd, data, err = self._xfer_frame(CMD_CONTROL, bytes([code]))
        return err

    def read_result(self, num_bins=64):
        """Read FFT result bins (real part only, 2 bytes/bin)."""
        cmd, data, err = self._xfer_frame(
            CMD_READ_RESULT,
            bytes([num_bins]),
            expected_len=num_bins * 2
        )
        if err:
            return None, err
        if len(data) < num_bins * 2:
            return None, f"Got {len(data)} bytes, expected {num_bins * 2}"

        bins = np.zeros(num_bins, dtype=complex)
        for i in range(num_bins):
            hi = data[i * 2]
            lo = data[i * 2 + 1]
            val = (hi << 8) | lo
            if val & 0x8000:
                val = -((~val & 0xFFFF) + 1)
            bins[i] = complex(val / 32767.0, 0.0)
        return bins, None

    def read_all_bins(self, total=1024, chunk=60):
        """Read all bins in chunks. Returns complex array."""
        all_bins = np.zeros(total, dtype=complex)
        for offset in range(0, total, chunk):
            n = min(chunk, total - offset)
            bins, err = self.read_result(n)
            if err:
                return None, f"Chunk {offset}: {err}"
            all_bins[offset:offset+n] = bins
        return all_bins, None

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
