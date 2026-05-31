#!/usr/bin/env python3
"""
chirp_test.py — Chirp 18-34 kHz: FPGA simulation vs FFTW comparison

Generates a linear chirp, runs FPGA simulation (Docker iverilog),
computes FFTW reference, and plots both spectra.
"""

import sys, os, subprocess, numpy as np
import matplotlib.pyplot as plt

# Parameters
N      = 1024
WIDTH  = 16
MAX_Q  = (1 << (WIDTH - 1)) - 1  # 32767
FS     = 100e3   # Sampling rate: 100 kHz (Nyquist for 34 kHz)
F0     = 18e3    # Chirp start: 18 kHz
F1     = 34e3    # Chirp end:   34 kHz

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
SIM_DIR    = os.path.abspath(os.path.join(SCRIPT_DIR, '..', 'sim'))
WORKSPACE  = os.path.abspath(os.path.join(SCRIPT_DIR, '..', '..'))
INPUT_HEX  = os.path.join(SIM_DIR, 'fft_input.hex')
OUTPUT_HEX = os.path.join(SIM_DIR, 'fft_output.hex')

# ══════════════════════════════════════════════════
# 1. Generate chirp signal
# ══════════════════════════════════════════════════

t = np.arange(N) / FS
chirp_float = np.sin(2 * np.pi * (F0 * t + (F1 - F0) * t**2 / (2 * t[-1])))

# Scale to avoid overflow: max FFT bin ≈ N * amplitude/2
# For 1024-point: max bin ≈ 512 * amplitude
# To keep within ±32767: amplitude ≤ 32767/512 ≈ 64
amplitude = 60
chirp_float *= amplitude

# Quantize to int16 (same as FPGA Q1.15 input)
chirp_i16 = np.round(chirp_float).astype(np.int16)

print(f"Chirp: {F0/1e3:.0f}-{F1/1e3:.0f} kHz, Fs={FS/1e3:.0f} kHz, N={N}")
print(f"Amplitude: ±{amplitude}, max sample: {np.max(np.abs(chirp_i16))}")
print(f"Bin resolution: {FS/N:.1f} Hz")
print(f"Chirp bins: {int(F0*N/FS)}-{int(F1*N/FS)}")

# ══════════════════════════════════════════════════
# 2. FFTW3 reference (via numpy float64)
# ══════════════════════════════════════════════════

ref_float = np.fft.fft(chirp_float.astype(np.float64))
ref_mag   = np.abs(ref_float)

# ══════════════════════════════════════════════════
# 3. FPGA simulation (Docker)
# ══════════════════════════════════════════════════

# Write input hex file
with open(INPUT_HEX, 'w') as f:
    for v in chirp_i16:
        word = int(v) & 0xFFFF
        f.write(f"{word:08x}\n")

# Run simulation
iverilog_cmd = (
    'iverilog -g2012 -Wall -I ../rtl '
    '-o build/tb_fft_compare.vvp '
    'tb_fft_compare.v ../rtl/fft_core.v ../rtl/twiddle_rom.v ice40_stubs.v'
)
vvp_cmd = 'vvp build/tb_fft_compare.vvp'
shell_cmd = f'mkdir -p build && cp twiddle.hex build/ 2>/dev/null; {iverilog_cmd} 2>&1 && {vvp_cmd}'

print("\nRunning FPGA simulation...")
result = subprocess.run(
    ['docker', 'run', '--rm',
     '-v', f'{WORKSPACE}:/workspace',
     '-w', '/workspace/hardware/sim',
     'ice40-fft', 'sh', '-c', shell_cmd],
    capture_output=True, text=True, timeout=120
)
if result.returncode != 0 or 'ERROR' in result.stdout:
    print("SIM FAILED:")
    print(result.stdout[-500:])
    print(result.stderr[-500:])
    sys.exit(1)
print(result.stdout.strip())

# Read FPGA output
fpga_out = []
with open(OUTPUT_HEX) as f:
    for line in f:
        line = line.strip()
        if not line: continue
        word = int(line, 16)
        re_u = word & 0xFFFF
        im_u = (word >> 16) & 0xFFFF
        re = re_u - 0x10000 if re_u >= 0x8000 else re_u
        im = im_u - 0x10000 if im_u >= 0x8000 else im_u
        fpga_out.append(complex(re, im))
fpga_out = np.array(fpga_out[:N])
fpga_mag = np.abs(fpga_out)

# ══════════════════════════════════════════════════
# 4. Plot
# ══════════════════════════════════════════════════

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

# FFTW spectrum
ax2.plot(freq[:N//2] / 1e3, ref_mag[:N//2], 'b-', linewidth=0.7, label='FFTW float64')
ax2.axvspan(F0/1e3, F1/1e3, alpha=0.1, color='orange', label=f'{F0/1e3:.0f}-{F1/1e3:.0f} kHz')
ax2.set_xlabel('Frequency (kHz)')
ax2.set_ylabel('|X[k]|')
ax2.set_title('FFTW3 (numpy float64) — Reference')
ax2.legend()
ax2.grid(True, alpha=0.3)

# FPGA spectrum
ax3.plot(freq[:N//2] / 1e3, fpga_mag[:N//2], 'r-', linewidth=0.7, label='FPGA Q1.15')
ax3.axvspan(F0/1e3, F1/1e3, alpha=0.1, color='orange', label=f'{F0/1e3:.0f}-{F1/1e3:.0f} kHz')
ax3.set_xlabel('Frequency (kHz)')
ax3.set_ylabel('|X[k]|')
ax3.set_title('FPGA (ICE40, 16-bit Q1.15 Radix-2 DIT) — Simulation')
ax3.legend()
ax3.grid(True, alpha=0.3)

# Correlation
corr = np.corrcoef(fpga_mag, ref_mag)[0, 1]
max_diff = np.max(np.abs(fpga_mag - ref_mag))
fig.suptitle(f'Chirp FFT Comparison  |  Correlation: {corr:.6f}  |  Max |Δ|: {max_diff:.0f}',
             fontsize=12, fontweight='bold')

plt.tight_layout()
outfile = os.path.join(SCRIPT_DIR, 'chirp_fft_comparison.png')
plt.savefig(outfile, dpi=150)
print(f"\nPlot saved: {outfile}")
plt.close()
