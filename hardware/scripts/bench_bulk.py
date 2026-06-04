#!/usr/bin/env python3
"""bench_bulk.py — chunked READ_RESULT vs streaming BULK_READ on hardware.

Preloads a ramp, runs the FFT once, then times two readout paths over many
iterations:
  • read_all_bins(hermitian)  — chunked 0x21, 9 SPI transactions of <=63 bins
  • bulk_read(hermitian)      — streaming 0x23, ONE SPI transaction

Both return the full N-point spectrum; we cross-check that they agree and
report the per-iteration readout time and the speedup.
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
    proto = FftProto()
    flags, err = proto.status()
    if err:
        print(f"STATUS error: {err}"); sys.exit(1)
    if flags['busy']:
        proto.wait_done(timeout=5.0, poll_ms=1)

    print("Preloading ramp 0..1023...")
    err = proto.write_data(np.arange(N, dtype=np.float64))
    if err:
        print(f"WRITE_DATA error: {err}"); sys.exit(1)

    proto.control(CTRL_START)
    if not proto.wait_done(timeout=5.0, poll_ms=1):
        print("FFT did not complete!"); sys.exit(1)

    # Correctness: both paths must match numpy.fft of the ramp.
    ref = np.fft.fft(np.arange(N, dtype=np.float64))
    chunk_bins, err = proto.read_all_bins(N, chunk=63, hermitian=True)
    if err:
        print(f"chunked read error: {err}"); sys.exit(1)
    bulk_bins, err = proto.bulk_read(N, hermitian=True)
    if err:
        print(f"bulk read error: {err}"); sys.exit(1)

    agree = np.allclose(chunk_bins, bulk_bins)
    corr_chunk = np.corrcoef(np.abs(chunk_bins), np.abs(ref))[0, 1]
    corr_bulk = np.corrcoef(np.abs(bulk_bins), np.abs(ref))[0, 1]
    print(f"chunked vs bulk identical: {agree}")
    print(f"corr vs numpy: chunked={corr_chunk:.6f}  bulk={corr_bulk:.6f}")

    # Timing.
    t_chunk, t_bulk = [], []
    for _ in range(RUNS):
        t0 = time.perf_counter(); proto.read_all_bins(N, chunk=63, hermitian=True)
        t_chunk.append(time.perf_counter() - t0)
        t0 = time.perf_counter(); proto.bulk_read(N, hermitian=True)
        t_bulk.append(time.perf_counter() - t0)
    proto.close()

    mc, mb = np.mean(t_chunk) * 1000, np.mean(t_bulk) * 1000
    print(f"\n{'='*52}")
    print(f"  Readout time (hermitian, N={N}, {RUNS} runs)")
    print(f"{'='*52}")
    print(f"  chunked READ_RESULT (0x21): {mc:7.2f} ms")
    print(f"  bulk    BULK_READ   (0x23): {mb:7.2f} ms")
    print(f"  speedup: {mc/mb:.2f}x")


if __name__ == '__main__':
    main()
