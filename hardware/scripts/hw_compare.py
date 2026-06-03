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

    # ── BFP exponent (for tolerance scaling) ─────
    flags2, _ = proto.status()
    exp = flags2['exp'] if flags2 else 0

    # ── Read result ──────────────────────────────
    print(f"Reading {N} bins...")
    t0 = time.time()
    bins, err = proto.read_all_bins(N)   # already rescaled by 2**exp
    dt_read = time.time() - t0
    if err:
        print(f"READ_RESULT error: {err}")
        proto.close()
        sys.exit(1)
    print(f"Read {N} bins in {dt_read:.3f}s ({N/dt_read:.0f} bins/s)  BFP exp={exp}")

    proto.close()

    # ── Reference: true FFT of the integer ramp 0..N-1 ──
    ref = np.fft.fft(np.arange(N, dtype=np.float64))

    fpga_re = np.round(np.real(bins)).astype(np.int64)
    fpga_im = np.round(np.imag(bins)).astype(np.int64)
    ref_re  = np.round(ref.real).astype(np.int64)
    ref_im  = np.round(ref.imag).astype(np.int64)

    d_re = np.abs(fpga_re - ref_re)
    d_im = np.abs(fpga_im - ref_im)

    # Each stored LSB equals 2**exp in true units → tolerance scales with it.
    tol_lsb = 32
    tol = tol_lsb * (1 << exp)
    max_err = int(max(np.max(d_re), np.max(d_im)))
    failed = int(np.sum((d_re > tol) | (d_im > tol)))

    print(f"\n{'Bin':>6s}  {'FPGA re':>10s} {'FPGA im':>10s}  "
          f"{'Ref re':>10s} {'Ref im':>10s}  {'dRe':>7s} {'dIm':>7s}")
    print("-" * 75)
    for i in range(min(N, 16)):
        print(f"{i:6d}  {fpga_re[i]:10d} {fpga_im[i]:10d}  "
              f"{ref_re[i]:10d} {ref_im[i]:10d}  "
              f"{d_re[i]:7d} {d_im[i]:7d}")
    if N > 16:
        print(f"... ({N-16} more bins)")

    ref_mag = np.abs(ref)
    fpga_mag = np.abs(bins)
    corr = np.corrcoef(fpga_mag, ref_mag)[0, 1]

    print(f"\nMax error : {max_err}  (tolerance ±{tol} = {tol_lsb} LSB << {exp})")
    print(f"Failed    : {failed}/{N} bins")
    print(f"Correlation |X|: {corr:.6f}")

    if stats_mode:
        print(f"\n--- Statistics ---")
        print(f"FFT time  : {dt:.3f}s")
        print(f"Read time : {dt_read:.3f}s")
        print(f"Total time: {dt + dt_read:.3f}s")
        print(f"DC bin    : FPGA={fpga_re[0]}, Ref={ref_re[0]}")

    if failed == 0:
        print(f"\n*** ALL {N} BINS PASS ***")
    else:
        print(f"\n*** {failed}/{N} BINS FAILED ***")


if __name__ == "__main__":
    main()
