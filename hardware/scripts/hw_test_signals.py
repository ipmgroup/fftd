#!/usr/bin/env python3
"""
hw_test_signals.py — On-hardware FFT regression: DC, ramp, sin, chirp.

Runs each test signal through the FPGA on the iceZero/RPi and compares the
spectrum against a numpy reference. Each signal is exercised through BOTH
input paths:
  - BRAM  : WRITE_DATA  (0x41) direct-to-BRAM staging (legacy)
  - SRAM  : WRITE_SRAM  (0x43) SRAM-staged input + input-DMA (double-buffer)

Reports magnitude correlation per signal/path; PASS if corr >= THRESHOLD.

Run on the Pi (after flashing the bitstream):
    python3 hardware/scripts/hw_test_signals.py
"""

import sys, os, time, numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from fft_proto import FftProto, CTRL_START

N         = 1024
FS        = 100e3
THRESHOLD = 0.999


def make_signals():
    n = np.arange(N)
    sigs = {}
    sigs['DC']    = np.full(N, 1000, dtype=np.int16)
    sigs['ramp']  = (n % N).astype(np.int16)                       # 0..1023
    sigs['sin']   = np.round(1000 * np.sin(2*np.pi*100*n/N)).astype(np.int16)  # bin 100
    t = n / FS
    chirp = np.sin(2*np.pi*(18e3*t + (34e3-18e3)*t**2/(2*t[-1])))
    sigs['chirp'] = np.round(60 * chirp).astype(np.int16)
    return sigs


def run_one(proto, samples, use_sram):
    """Stage a frame, run the FFT, return the rescaled complex spectrum."""
    samples = samples.astype(np.float64)
    if use_sram:
        err = proto.write_data_sram(samples)
    else:
        err = proto.write_data(samples)
    if err:
        return None, f"write error: {err}"
    time.sleep(0.02)
    proto.control(CTRL_START)
    if not proto.wait_done(timeout=5.0, poll_ms=20):
        return None, "FFT timeout"
    bins, err = proto.bulk_read(N, rescale=True, hermitian=True)
    if err:
        return None, f"read error: {err}"
    return bins, None


def main():
    sigs = make_signals()
    proto = FftProto()

    flags, err = proto.status()
    if err:
        print(f"STATUS error: {err} — is the bitstream flashed?")
        sys.exit(1)
    print(f"STATUS: ready={flags['ready']} busy={flags['busy']} done={flags['done']}\n")

    print(f"{'signal':>7s} {'path':>5s} {'corr':>10s} {'rel_err':>9s} {'fpga_peak_bin':>14s} {'ref_peak_bin':>13s}  result")
    print("-" * 78)

    n_fail = 0
    for name, s in sigs.items():
        ref = np.fft.fft(s.astype(np.float64))
        ref_mag = np.abs(ref)
        for use_sram in (False, True):
            path = 'SRAM' if use_sram else 'BRAM'
            bins, e = run_one(proto, s, use_sram)
            if e:
                print(f"{name:>7s} {path:>5s} {'--':>10s} {'--':>9s} {'--':>14s} {'--':>13s}  FAIL ({e})")
                n_fail += 1
                continue
            fpga_mag = np.abs(bins)
            corr = np.corrcoef(fpga_mag, ref_mag)[0, 1]
            scale = ref_mag.max() / fpga_mag.max() if fpga_mag.max() > 0 else 1.0
            rel = np.max(np.abs(fpga_mag * scale - ref_mag)) / ref_mag.max()
            ok = corr >= THRESHOLD
            if not ok:
                n_fail += 1
            print(f"{name:>7s} {path:>5s} {corr:10.6f} {rel:9.4f} "
                  f"{int(np.argmax(fpga_mag)):14d} {int(np.argmax(ref_mag)):13d}  "
                  f"{'PASS' if ok else 'FAIL'}")

    proto.close()
    print("-" * 78)
    if n_fail == 0:
        print("ALL HARDWARE TESTS PASSED")
        sys.exit(0)
    print(f"{n_fail} HARDWARE TEST(S) FAILED")
    sys.exit(1)


if __name__ == '__main__':
    main()
