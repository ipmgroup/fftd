#!/usr/bin/env python3
"""bench_pipeline.py — compute/readout overlap (SRAM double-buffer, B2).

The FFT result is copied to external SRAM after each frame, so the host can
stream frame N from SRAM while the core already computes frame N+1 in BRAM
(the copy of N+1 is deferred in hardware until the read of N finishes).

Two host loops are compared, both using BULK_READ + Hermitian:

  serial    : START → wait_done (compute+DMA) → read          (no overlap)
  pipelined : START(n+1) → read(n) → wait_done                (compute hidden
              under the readout of the previous frame)

The internal ramp generator feeds every frame, so each spectrum equals
numpy.fft.fft(0..N-1); we verify the correlation on every pipelined read.
"""
import sys, time
import numpy as np
sys.path.insert(0, '.')
try:
    from hardware.scripts.fft_proto import FftProto, CTRL_START
except ImportError:
    from fft_proto import FftProto, CTRL_START

N = 1024
RUNS = 30


def main():
    p = FftProto(speed=14000000)
    f, _ = p.status()
    if f['busy']:
        p.wait_done(5, 1)

    ref = np.abs(np.fft.fft(np.arange(N, dtype=np.float64)))

    # ── Serial baseline ──────────────────────────
    p.control(CTRL_START); p.wait_done(5, 1)
    t0 = time.perf_counter()
    for _ in range(RUNS):
        p.control(CTRL_START)
        p.wait_done(5, 1)
        bins, err = p.bulk_read(N, hermitian=True)
    t_serial = (time.perf_counter() - t0) / RUNS

    # ── Pipelined (overlap) ──────────────────────
    p.control(CTRL_START); p.wait_done(5, 1)   # prime frame 0
    fails = 0
    t0 = time.perf_counter()
    for _ in range(RUNS):
        p.control(CTRL_START)                  # kick next compute
        bins, err = p.bulk_read(N, hermitian=True)   # read previous (overlaps)
        if err or np.corrcoef(np.abs(bins), ref)[0, 1] < 0.999:
            fails += 1
        p.wait_done(5, 1)                      # ensure this frame's DMA done
    t_pipe = (time.perf_counter() - t0) / RUNS
    p.close()

    print(f"{'='*52}")
    print(f"  Compute/readout overlap (N={N}, {RUNS} frames, 14 MHz)")
    print(f"{'='*52}")
    print(f"  serial     : {t_serial*1000:6.2f} ms/frame")
    print(f"  pipelined  : {t_pipe*1000:6.2f} ms/frame")
    print(f"  speedup    : {t_serial/t_pipe:.2f}x")
    print(f"  throughput : {1.0/t_pipe:6.1f} FFT/s (was {1.0/t_serial:.1f})")
    print(f"  correctness: {RUNS-fails}/{RUNS} pipelined reads corr>=0.999")


if __name__ == '__main__':
    main()
