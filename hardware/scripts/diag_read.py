#!/usr/bin/env python3
import sys, time
sys.path.insert(0, '.')
import numpy as np
from fft_proto import FftProto, CTRL_START

N = 1024
k = 16
x = np.round(20000 * np.sin(2 * np.pi * k * np.arange(N) / N)).astype(np.int64)
ref = np.fft.fft(x.astype(np.float64))

proto = FftProto(speed=2_000_000)
f, _ = proto.status()
if f and f['busy']:
    proto.wait_done(timeout=5.0, poll_ms=1)
proto.write_data(x)
proto.control(CTRL_START)
proto.wait_done(timeout=5.0, poll_ms=1)

# Full read, no hermitian
bins, err = proto.read_all_bins(N, chunk=60, hermitian=False)
print("err:", err)
mag = np.abs(bins)
peak = int(np.argmax(mag[1:N//2]) + 1)
print(f"peak bin (no-herm): {peak}  (expect 16)")
print(f"corr full: {np.corrcoef(mag, np.abs(ref))[0,1]:.5f}")
print("\nfirst 6 bins raw (re, im) vs numpy:")
for i in range(6):
    print(f"  bin{i}: fpga=({bins[i].real:8.0f},{bins[i].imag:8.0f})  np=({ref[i].real:10.1f},{ref[i].imag:10.1f})")
print("\nbins 14..18:")
for i in range(14, 19):
    print(f"  bin{i}: fpga=({bins[i].real:8.0f},{bins[i].imag:8.0f})  np=({ref[i].real:10.1f},{ref[i].imag:10.1f})")
proto.close()
