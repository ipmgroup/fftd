#!/usr/bin/env python3
"""spi_sweep.py — sweep SPI SCK and measure readout reliability + speed.

Loads a sine once, runs the FFT once, then reads all bins repeatedly at a
range of SCK frequencies. For each frequency reports: failures (protocol
errors), correlation of magnitude vs numpy, peak bin, and avg readout time.
"""
import sys, time
sys.path.insert(0, '.')
import numpy as np
from fft_proto import FftProto, CTRL_START

N = 1024
REPS = 4
SPEEDS = [4, 6, 8, 10, 12, 16, 20, 24, 32]   # MHz

# Reference sine: 16 cycles over N, amplitude near full-scale
k = 16
x = np.round(20000 * np.sin(2 * np.pi * k * np.arange(N) / N)).astype(np.int64)
ref = np.fft.fft(x.astype(np.float64))
ref_mag = np.abs(ref)
peak_ref = int(np.argmax(ref_mag[1:N // 2]) + 1)

proto = FftProto(speed=4_000_000)
f, _ = proto.status()
if f and f['busy']:
    proto.wait_done(timeout=5.0, poll_ms=1)

print("Preloading sine...")
err = proto.write_data(x)
if err:
    print(f"WRITE_DATA error: {err}")
    sys.exit(1)
proto.control(CTRL_START)
if not proto.wait_done(timeout=5.0, poll_ms=1):
    print("FFT did not complete")
    sys.exit(1)
print(f"FFT done. numpy peak bin = {peak_ref}\n")

for herm in (False, True):
    print(f"\n=== hermitian={herm} ===")
    print(f"{'SCK MHz':>8s} {'fails':>6s} {'corr':>9s} {'peak':>6s} {'read ms':>9s}")
    print("-" * 44)
    for mhz in SPEEDS:
        proto.spi.max_speed_hz = mhz * 1_000_000
        fails = 0
        corrs = []
        peaks = []
        times = []
        for _ in range(REPS):
            # FFT is in-place + rd_bin resets only on fft_done → reload data
            # and recompute before each read so every read starts at bin 0.
            proto.spi.max_speed_hz = 2_000_000
            proto.write_data(x)
            proto.control(CTRL_START)
            proto.wait_done(timeout=5.0, poll_ms=1)
            proto.spi.max_speed_hz = mhz * 1_000_000
            t0 = time.perf_counter()
            bins, err = proto.read_all_bins(N, chunk=60, hermitian=herm)
            dt = time.perf_counter() - t0
            if err or bins is None:
                fails += 1
                continue
            times.append(dt)
            mag = np.abs(bins)
            corrs.append(np.corrcoef(mag, ref_mag)[0, 1])
            peaks.append(int(np.argmax(mag[1:N // 2]) + 1))
        corr = np.mean(corrs) if corrs else float('nan')
        peak = max(set(peaks), key=peaks.count) if peaks else -1
        rms = np.mean(times) * 1000 if times else float('nan')
        flag = "" if (fails == 0 and peak == peak_ref and corr > 0.999) else "  <-- BAD"
        print(f"{mhz:8d} {fails:6d} {corr:9.5f} {peak:6d} {rms:9.2f}{flag}")

proto.close()
