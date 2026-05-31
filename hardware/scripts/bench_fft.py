#!/usr/bin/env python3
"""
bench_fft.py — FPGA vs CPU FFT performance benchmark (Raspberry Pi)

Compares:
  FPGA (ICE40HX4K, 50 MHz, Radix-2, 16-bit Q1.15)
  numpy.fft (float64, NEON-optimized)
  FFTW via pyfftw (float32, if available)
  scipy.fft (float64, if available)
"""

import sys, time, numpy as np

sys.path.insert(0, '.')
from hardware.scripts.fft_proto import FftProto, CMD_CONTROL, CTRL_START, CTRL_RESET

N = 1024
WARMUP = 3
RUNS   = 5
MAX_Q  = 32767

# ── Test signal: ramp 0..N-1 (same as FPGA) ──
ramp_i16 = np.arange(N, dtype=np.int16)
ramp_f32 = ramp_i16.astype(np.float32)
ramp_f64 = ramp_i16.astype(np.float64)

# ══════════════════════════════════════════════════
# FPGA FFT
# ══════════════════════════════════════════════════

print("=" * 60)
print("FPGA FFT (ICE40HX4K, 50 MHz, 16-bit Q1.15)")
print("=" * 60)

proto = FftProto(speed=8000000)

# Warmup
for _ in range(WARMUP):
    proto.control(CTRL_START)
    proto.wait_done(timeout=5.0)

fpga_times = []
fpga_read_times = []
for r in range(RUNS):
    proto.control(CTRL_START)
    t0 = time.perf_counter()
    ok = proto.wait_done(timeout=5.0)
    t_fft = time.perf_counter() - t0
    if not ok:
        print(f"  Run {r}: FFT TIMEOUT!")
        continue

    t0 = time.perf_counter()
    bins, err = proto.read_all_bins(N, chunk=120)
    t_read = time.perf_counter() - t0
    if bins is None:
        print(f"  Run {r}: READ ERROR: {err}")
        continue

    fpga_times.append(t_fft)
    fpga_read_times.append(t_read)
    print(f"  Run {r}: compute={t_fft*1000:.2f}ms  read={t_read*1000:.2f}ms  total={(t_fft+t_read)*1000:.2f}ms")

proto.close()

fpga_fft_ms  = np.mean(fpga_times) * 1000 if fpga_times else 0
fpga_read_ms = np.mean(fpga_read_times) * 1000 if fpga_read_times else 0
fpga_total_ms = fpga_fft_ms + fpga_read_ms

# ══════════════════════════════════════════════════
# numpy.fft (float64)
# ══════════════════════════════════════════════════

print(f"\n{'='*60}")
print("numpy.fft.fft (float64, NEON)")
print("=" * 60)

for _ in range(WARMUP):
    np.fft.fft(ramp_f64)

np_times = []
for r in range(RUNS):
    t0 = time.perf_counter()
    result = np.fft.fft(ramp_f64)
    t = time.perf_counter() - t0
    np_times.append(t)
    print(f"  Run {r}: {t*1000:.3f}ms")

np_ms = np.mean(np_times) * 1000

# ══════════════════════════════════════════════════
# numpy.fft (float32)
# ══════════════════════════════════════════════════

print(f"\n{'='*60}")
print("numpy.fft.fft (float32)")
print("=" * 60)

for _ in range(WARMUP):
    np.fft.fft(ramp_f32)

np32_times = []
for r in range(RUNS):
    t0 = time.perf_counter()
    result = np.fft.fft(ramp_f32)
    t = time.perf_counter() - t0
    np32_times.append(t)
    print(f"  Run {r}: {t*1000:.3f}ms")

np32_ms = np.mean(np32_times) * 1000

# ══════════════════════════════════════════════════
# pyfftw (FFTW3 float32)
# ══════════════════════════════════════════════════

pyfftw_ms = 0
try:
    import pyfftw
    print(f"\n{'='*60}")
    print("pyfftw (FFTW3 float32, single-precision)")
    print("=" * 60)

    in_fftw  = pyfftw.empty_aligned(N, dtype='complex64')
    out_fftw = pyfftw.empty_aligned(N, dtype='complex64')
    in_fftw[:] = ramp_f32.astype(np.complex64)

    fftw_plan = pyfftw.FFTW(in_fftw, out_fftw, flags=('FFTW_MEASURE',))
    # Plan once
    fftw_plan()

    for r in range(RUNS):
        in_fftw[:] = ramp_f32.astype(np.complex64)
        t0 = time.perf_counter()
        fftw_plan()
        t = time.perf_counter() - t0
        print(f"  Run {r}: {t*1000:.3f}ms")

    pyfftw_ms = np.mean([
        (lambda: (time.perf_counter() - (t0:=0), fftw_plan())[0] if False else (
            t0 := time.perf_counter(), fftw_plan(), time.perf_counter() - t0
        )[-1])() 
        for _ in range(RUNS)
    ]) * 1000  # redo properly
except ImportError:
    print("  pyfftw not installed. Install: pip3 install pyfftw")

# ══════════════════════════════════════════════════
# Summary
# ══════════════════════════════════════════════════

print(f"\n{'='*60}")
print(f"{'BENCHMARK SUMMARY':^60}")
print(f"{'='*60}")
print(f"  N = {N} points")
print(f"  Test signal: ramp 0..{N-1}")
print()
print(f"  {'Method':<30s} {'Time':>10s}  {'Speedup':>10s}")
print(f"  {'-'*30} {'-'*10}  {'-'*10}")

def row(name, ms):
    speedup = np_ms / ms if ms > 0 else 0
    print(f"  {name:<30s} {ms:8.2f}ms  {speedup:9.2f}x")

row("FPGA (compute only)", fpga_fft_ms)
row("FPGA (readout only)", fpga_read_ms)
row("FPGA (total)", fpga_total_ms)
row("numpy.fft float64", np_ms)
row("numpy.fft float32", np32_ms)

# pyfftw average
pyfftw_avg = 0
try:
    import pyfftw
    in_fftw[:] = ramp_f32.astype(np.complex64)
    times = []
    for _ in range(RUNS):
        t0 = time.perf_counter()
        fftw_plan()
        times.append(time.perf_counter() - t0)
    pyfftw_avg = np.mean(times) * 1000
    row("pyfftw FFTW3 float32", pyfftw_avg)
except:
    pass

print()
print(f"  Baseline: numpy float64 = {np_ms:.2f}ms")
print(f"  FPGA speedup vs numpy64: {np_ms/fpga_total_ms:.2f}x" if fpga_total_ms > 0 else "")
print(f"  FPGA throughput: {N/fpga_total_ms*1000:.0f} bins/s" if fpga_total_ms > 0 else "")
