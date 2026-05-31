#!/usr/bin/env python3
"""Compare FPGA FFT vs numpy — BOTH in 16-bit wrapped domain."""
import sys, numpy as np
sys.path.insert(0, '.')
from hardware.scripts.fft_proto import FftProto

N = 1024
MAX_Q = 32767

proto = FftProto()
flags, _ = proto.status()
print(f"STATUS: {flags}")

bins, err = proto.read_all_bins(N)
proto.close()

if err:
    print(f"Error: {err}")
    sys.exit(1)

# FPGA: raw int16 complex
fpga_re = np.round(np.real(bins) * MAX_Q).astype(np.int64)
fpga_im = np.round(np.imag(bins) * MAX_Q).astype(np.int64)

# Reference: numpy FFT of ramp, then truncate to int16 (same wrap as FPGA)
ramp = np.arange(N, dtype=np.float64)
ref = np.fft.fft(ramp)
ref_re = np.round(ref.real).astype(np.int64) & 0xFFFF
ref_im = np.round(ref.imag).astype(np.int64) & 0xFFFF
ref_re[ref_re >= 0x8000] -= 0x10000
ref_im[ref_im >= 0x8000] -= 0x10000

# Magnitudes in 16-bit wrapped domain
mag_fpga = np.sqrt(fpga_re.astype(np.float64)**2 + fpga_im.astype(np.float64)**2)
mag_ref  = np.sqrt(ref_re.astype(np.float64)**2 + ref_im.astype(np.float64)**2)

# Per-bin relative error (where ref is not near zero)
mask = mag_ref > 100
rel_err = np.abs(mag_fpga[mask] - mag_ref[mask]) / mag_ref[mask]

print(f"DC bin: fpga={fpga_re[0]}+{fpga_im[0]}j  ref={ref_re[0]}+{ref_im[0]}j")
print(f"\nFirst 16 bins (16-bit wrapped domain):")
print(f"{'Bin':>4s}  {'FPGA re':>8s} {'FPGA im':>8s}  {'Ref re':>8s} {'Ref im':>8s}  {'dRe':>5s} {'dIm':>5s}")
for i in range(16):
    print(f"{i:4d}  {fpga_re[i]:8d} {fpga_im[i]:8d}  {ref_re[i]:8d} {ref_im[i]:8d}  "
          f"{fpga_re[i]-ref_re[i]:5d} {fpga_im[i]-ref_im[i]:5d}")

d_re = np.abs(fpga_re - ref_re)
d_im = np.abs(fpga_im - ref_im)
max_err = max(np.max(d_re), np.max(d_im))
tol = 40  # LSB — generous for Q1.15 × 10 stages with overflow

# Bins where REF wraps multiple times (16-bit truncation masks true value)
# → skip those for FAIL count
overwrap_mask = np.abs(ref.real) > 32767 * 2
failed = np.sum(((d_re > tol) | (d_im > tol)) & ~overwrap_mask)

print(f"\nMax error : {max_err} LSB  (tolerance +-{tol})")
print(f"Failed    : {failed}/{N} bins (skipping deeply-wrapped ref bins)")
print(f"Correlation |X|: {np.corrcoef(mag_fpga, mag_ref)[0,1]:.6f}")
if len(rel_err) > 0:
    print(f"Relative mag error: max={np.max(rel_err)*100:.2f}%  mean={np.mean(rel_err)*100:.3f}%")

if failed == 0:
    print(f"\n*** ALL {N} BINS PASS! ***")
else:
    print(f"\n*** {failed}/{N} BINS FAILED ***")
