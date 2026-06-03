#!/usr/bin/env python3
"""
hw_compare.py — Compare FPGA FFT (hardware via SPI) vs numpy.fft.fft()

Usage (on Raspberry Pi):
  python3 hw_compare.py
  python3 hw_compare.py --stats
"""

import sys
import time
import numpy as np

# Import from sibling dir
sys.path.insert(0, '.')
try:
    from hardware.scripts.fft_proto import FftProto, CMD_CONTROL, CTRL_START, CTRL_RESET
except ImportError:
    from fft_proto import FftProto, CMD_CONTROL, CTRL_START, CTRL_RESET

N = 1024
MAX_Q = 32767


def main():
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

    # ── Reset ─────────────────────────────────────
    if flags['busy']:
        print("Resetting FPGA...")
        proto.control(CTRL_RESET)
        time.sleep(0.1)

    # ── Write ramp data (0..N-1) ──────────────────
    print(f"Writing ramp 0..{N-1} to FPGA...")
    ramp = np.arange(N, dtype=np.int16)
    err = proto.write_data(ramp.astype(np.float64))
    if err:
        print(f"WRITE_DATA error: {err}")
        proto.close()
        sys.exit(1)
    print("  done")

    # ── Start FFT ────────────────────────────────
    print("Starting FFT...")
    err = proto.control(CTRL_START)
    if err:
        print(f"CONTROL error: {err}")

    # ── Wait for done ────────────────────────────
    print("Waiting for FFT completion...")
    t0 = time.time()
    ok = proto.wait_done(timeout=10.0)
    dt = time.time() - t0
    if not ok:
        print("FFT did not complete!")
        proto.close()
        sys.exit(1)
    print(f"FFT done in {dt:.3f}s")

    # ── Read result ──────────────────────────────
    print(f"Reading {N} bins...")
    t0 = time.time()
    bins, err = proto.read_all_bins(N)
    dt_read = time.time() - t0
    if err:
        print(f"READ_RESULT error: {err}")
        proto.close()
        sys.exit(1)
    print(f"Read {N} bins in {dt_read:.3f}s ({N/dt_read:.0f} bins/s)")

    proto.close()

    # ── Reference (ramp 0..N-1, imag=0) ──────────
    # CRITICAL: FPGA uses Q1.15 — input values 0..1023 represent 0/32768..1023/32768.
    # Numpy must use the SAME scale to compare.
    ramp = np.arange(N, dtype=np.float64) / MAX_Q   # Q1.15 scale
    ref = np.fft.fft(ramp)

    # ── Compare ───────────────────────────────────
    # FPGA: raw Q1.15 int → fft_proto divides by MAX_Q → multiply back
    fpga_i16 = np.round(np.real(bins) * MAX_Q).astype(np.int64)
    fpga_q16 = np.round(np.imag(bins) * MAX_Q).astype(np.int64)

    # Reference: Q1.15 float → scale to int16 → wrap like FPGA
    ref_i16_re = np.round(ref.real * MAX_Q).astype(np.int64)
    ref_i16_im = np.round(ref.imag * MAX_Q).astype(np.int64)
    ref_re_i16 = ref_i16_re & 0xFFFF
    ref_im_i16 = ref_i16_im & 0xFFFF
    ref_re_i16[ref_re_i16 >= 0x8000] -= 0x10000
    ref_im_i16[ref_im_i16 >= 0x8000] -= 0x10000

    d_re = np.abs(fpga_i16 - ref_re_i16)
    d_im = np.abs(fpga_q16 - ref_im_i16)

    max_err = max(np.max(d_re), np.max(d_im))
    tol = 32  # LSB for N=1024 (10 stages Q1.15 quantization)
    failed = np.sum((d_re > tol) | (d_im > tol))

    print(f"\n{'Bin':>6s}  {'FPGA re':>8s} {'FPGA im':>8s}  "
          f"{'Ref re':>8s} {'Ref im':>8s}  {'dRe':>5s} {'dIm':>5s}")
    print("-" * 65)
    for i in range(min(N, 64)):
        print(f"{i:6d}  {fpga_i16[i]:8d} {fpga_q16[i]:8d}  "
              f"{ref_re_i16[i]:8d} {ref_im_i16[i]:8d}  "
              f"{d_re[i]:5d} {d_im[i]:5d}")
    if N > 64:
        print(f"... ({N-64} more bins)")

    ref_mag = np.abs(ref)
    fpga_mag = np.sqrt(fpga_i16.astype(np.float64)**2 + fpga_q16.astype(np.float64)**2)
    corr = np.corrcoef(fpga_mag, ref_mag)[0, 1]

    print(f"\nMax error : {max_err} LSB  (tolerance ±{tol})")
    print(f"Failed    : {failed}/{N} bins")
    print(f"Correlation |X|: {corr:.6f}")

    if stats_mode:
        print(f"\n--- Statistics ---")
        print(f"FFT time  : {dt:.3f}s")
        print(f"Read time : {dt_read:.3f}s")
        print(f"Total time: {dt + dt_read:.3f}s")
        print(f"DC bin    : FPGA={fpga_i16[0]}, Ref={ref_re_i16[0]}")

    if failed == 0:
        print(f"\n*** ALL {N} BINS PASS ***")
    else:
        print(f"\n*** {failed}/{N} BINS FAILED ***")


if __name__ == "__main__":
    main()
