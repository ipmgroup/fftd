#!/usr/bin/env python3
import sys, time
sys.path.insert(0, '.')
import numpy as np
from fft_proto import FftProto, CTRL_START

N = 1024
k = 16
x = np.round(20000 * np.sin(2 * np.pi * k * np.arange(N) / N)).astype(np.int64)
ref_mag = np.abs(np.fft.fft(x.astype(np.float64)))

proto = FftProto(speed=4_000_000)
f, _ = proto.status()
if f and f['busy']:
    proto.wait_done(timeout=5.0, poll_ms=1)

# compute time (core @ 43.75 MHz now)
proto.write_data(x)
ct = []
for _ in range(10):
    proto.write_data(x)
    proto.control(CTRL_START)
    t0 = time.perf_counter()
    proto.wait_done(timeout=5.0, poll_ms=1)
    ct.append(time.perf_counter() - t0)
print(f"compute (poll_ms=1): {np.mean(ct)*1000:.2f} ms")

print(f"\n{'SCK MHz':>8s} {'fails':>6s} {'corr':>9s} {'peak':>6s} {'read ms':>9s}")
for mhz in [14, 15, 16, 17, 18, 19]:
    fails = 0; corrs = []; peaks = []; times = []
    for _ in range(6):
        proto.spi.max_speed_hz = 4_000_000
        proto.write_data(x); proto.control(CTRL_START); proto.wait_done(timeout=5, poll_ms=1)
        proto.spi.max_speed_hz = mhz * 1_000_000
        t0 = time.perf_counter()
        bins, err = proto.read_all_bins(N, chunk=60, hermitian=True)
        dt = time.perf_counter() - t0
        if err or bins is None:
            fails += 1; continue
        times.append(dt); mag = np.abs(bins)
        corrs.append(np.corrcoef(mag, ref_mag)[0, 1]); peaks.append(int(np.argmax(mag[1:N//2])+1))
    corr = np.mean(corrs) if corrs else float('nan')
    peak = max(set(peaks), key=peaks.count) if peaks else -1
    rms = np.mean(times)*1000 if times else float('nan')
    flag = "" if (fails == 0 and peak == 16 and corr > 0.999) else "  <-- BAD"
    print(f"{mhz:8d} {fails:6d} {corr:9.5f} {peak:6d} {rms:9.2f}{flag}")
proto.close()
