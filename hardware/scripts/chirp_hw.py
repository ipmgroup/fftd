#!/usr/bin/env python3
"""
chirp_hw.py — Chirp 18-34 kHz: FPGA hardware vs NumPy comparison

Sends chirp via SPI WRITE_DATA, reads FFT result, plots both spectra.
"""

import sys, os, time, numpy as np
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', '..'))
from hardware.scripts.fft_proto import FftProto

# Parameters
N      = 1024
FS     = 100e3
F0     = 18e3
F1     = 34e3

# ── Generate chirp ──────────────────────────────────
t = np.arange(N) / FS
chirp = np.sin(2 * np.pi * (F0 * t + (F1 - F0) * t**2 / (2 * t[-1])))
amplitude = 60
chirp *= amplitude
chirp_i16 = np.round(chirp).astype(np.int16)

# ── NumPy reference ─────────────────────────────────
ref = np.fft.fft(chirp_i16.astype(np.float64))
ref_mag = np.abs(ref)

# ── FPGA hardware ───────────────────────────────────
print(f"Chirp {F0/1e3:.0f}-{F1/1e3:.0f} kHz, N={N}, amp=±{amplitude}")
print("Connecting to FPGA...")
proto = FftProto(speed=8000000)

# Check status
flags, err = proto.status()
if err:
    print(f"STATUS error: {err}")
    sys.exit(1)
print(f"Status: ready={flags['ready']} busy={flags['busy']} done={flags['done']}")

# Send chirp via WRITE_DATA
print("Writing chirp to FPGA...")
err = proto.write_data(chirp_i16.astype(np.float64))
if err:
    print(f"WRITE_DATA error: {err}")
    sys.exit(1)
print("  done")

# Start FFT
time.sleep(0.05)
proto.control(0x01)
print("FFT started, waiting...")
ok = proto.wait_done(timeout=5.0, poll_ms=50)
if not ok:
    print("FFT timeout!")
    sys.exit(1)
print("  done")

# Read result
print("Reading result...")
bins, err = proto.read_all_bins(N, chunk=120)
if err:
    print(f"READ_RESULT error: {err}")
    sys.exit(1)
proto.close()

fpga_re = np.array([np.real(b) for b in bins])
fpga_im = np.array([np.imag(b) for b in bins])
fpga_cx = fpga_re + 1j * fpga_im
fpga_mag = np.abs(fpga_cx)

# ── Correlation ─────────────────────────────────────
corr = np.corrcoef(fpga_mag, ref_mag)[0, 1]
print(f"Correlation: {corr:.6f}")

# ── Plot ─────────────────────────────────────────────
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
freq = np.arange(N) * FS / N
chirp_lo = int(F0 * N / FS)
chirp_hi = int(F1 * N / FS)

fig, (ax1, ax2, ax3) = plt.subplots(3, 1, figsize=(12, 10))

# Time domain
ax1.plot(t * 1e3, chirp_i16, linewidth=0.5)
ax1.set_xlabel('Time (ms)')
ax1.set_ylabel('Amplitude (Q1.15)')
ax1.set_title(f'Chirp {F0/1e3:.0f}-{F1/1e3:.0f} kHz, Fs={FS/1e3:.0f} kHz, N={N}')
ax1.grid(True, alpha=0.3)

# FPGA spectrum
ax2.plot(freq / 1e3, fpga_mag, 'b-', linewidth=0.7, label='FPGA (hardware)')
ax2.axvspan(F0/1e3, F1/1e3, alpha=0.1, color='green', label=f'Chirp {F0/1e3:.0f}-{F1/1e3:.0f} kHz')
ax2.set_xlabel('Frequency (kHz)')
ax2.set_ylabel('Magnitude')
ax2.set_title(f'FPGA FFT Spectrum (corr={corr:.4f})')
ax2.legend(loc='upper right')
ax2.grid(True, alpha=0.3)

# NumPy spectrum
ax3.plot(freq / 1e3, ref_mag, 'r-', linewidth=0.7, label='NumPy (float64)')
ax3.axvspan(F0/1e3, F1/1e3, alpha=0.1, color='green')
ax3.set_xlabel('Frequency (kHz)')
ax3.set_ylabel('Magnitude')
ax3.set_title('NumPy FFTW Reference')
ax3.legend(loc='upper right')
ax3.grid(True, alpha=0.3)

plt.tight_layout()
outfile = os.path.join(SCRIPT_DIR, 'chirp_hw_comparison.png')
plt.savefig(outfile, dpi=150)
print(f"Plot saved: {outfile}")
