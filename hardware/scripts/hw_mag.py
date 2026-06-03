#!/usr/bin/env python3
"""Compare FPGA FFT vs numpy — REAL-ONLY (SPI reads only real part by design)."""
import sys, time, numpy as np
sys.path.insert(0, '.')
try:
    from hardware.scripts.fft_proto import FftProto
except ImportError:
    from fft_proto import FftProto

N = 1024
MAX_Q = 32767

proto = FftProto()
flags, _ = proto.status()
print(f"STATUS: {flags}")

print(f"Writing ramp 0..{N-1} to FPGA...")
ramp = np.arange(N, dtype=np.int16)
err = proto.write_data(ramp.astype(np.float64))
if err:
    print(f"WRITE_DATA error: {err}")
    sys.exit(1)
print("  done")

proto.control(0x01)
ok = proto.wait_done(timeout=5.0)
if not ok:
    print("FFT timeout!")
    sys.exit(1)

bins, err = proto.read_all_bins(N)
proto.close()
if err:
    print(f"Error: {err}")
    sys.exit(1)

fpga_re = np.round(np.real(bins) * MAX_Q).astype(np.int64)

ramp_q15 = np.arange(N, dtype=np.float64) / MAX_Q
ref = np.fft.fft(ramp_q15)
ref_re = np.round(ref.real * MAX_Q).astype(np.int64) & 0xFFFF
ref_re[ref_re >= 0x8000] -= 0x10000

d_re = np.abs(fpga_re - ref_re)
max_err = np.max(d_re)
tol = 80
failed = np.sum(d_re > tol)

print(f"\n{'Bin':>6s}  {'FPGA re':>8s}  {'Ref re':>8s}  {'dRe':>6s}")
print("-" * 38)
for i in range(16):
    print(f"{i:6d}  {fpga_re[i]:8d}  {ref_re[i]:8d}  {d_re[i]:6d}")

print(f"\nDC bin: fpga={fpga_re[0]} ref={ref_re[0]} err={d_re[0]}")
print(f"Max real error: {max_err} LSB  (tolerance +/-{tol})")
print(f"Failed bins: {failed}/{N}")
corr = np.corrcoef(fpga_re.astype(np.float64), ref_re.astype(np.float64))[0, 1]
print(f"Real correlation: {corr:.6f}")
print()
if failed == 0:
    print("ALL REAL BINS PASS!")
elif failed <= 5:
    print(f"{failed}/{N} bins outside tolerance (Q1.15 quantization)")
else:
    print(f"{failed}/{N} BINS FAILED")
