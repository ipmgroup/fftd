#!/usr/bin/env python3
"""
chirp_sim_sram.py — Chirp 18-34 kHz through the FULL simulated datapath.

Unlike chirp_test.py (which drives fft_core directly), this exercises the
complete fft_top path that the iceZero hat uses on the RPi: SPI WRITE_SRAM
(0x43) input staging → input-DMA (SRAM→BRAM) → FFT → output-DMA (BRAM→SRAM)
→ BULK_READ. It then compares the spectrum to a numpy reference and writes
chirp_fft_comparison.png.

Run inside the dev container (has iverilog + numpy + matplotlib):
    docker compose run --rm dev bash -c \
        "python3 hardware/scripts/chirp_sim_sram.py"
"""

import sys, os, subprocess, numpy as np
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt

# ── Parameters (match chirp_test.py / chirp_hw.py) ──────────────────
N         = 1024
WIDTH     = 16
FS        = 100e3
F0        = 18e3
F1        = 34e3
AMPLITUDE = 60

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
SIM_DIR    = os.path.abspath(os.path.join(SCRIPT_DIR, '..', 'sim'))
RTL_DIR    = os.path.abspath(os.path.join(SCRIPT_DIR, '..', 'rtl'))
INPUT_HEX  = os.path.join(SIM_DIR, 'fft_input.hex')
OUTPUT_HEX = os.path.join(SIM_DIR, 'fft_output.hex')

# ── 1) Generate chirp ───────────────────────────────────────────────
t = np.arange(N) / FS
chirp_float = np.sin(2 * np.pi * (F0 * t + (F1 - F0) * t**2 / (2 * t[-1])))
chirp_float *= AMPLITUDE
chirp_i16 = np.round(chirp_float).astype(np.int16)

print(f"Chirp: {F0/1e3:.0f}-{F1/1e3:.0f} kHz, Fs={FS/1e3:.0f} kHz, N={N}")
print(f"Amplitude: ±{AMPLITUDE}, max sample: {np.max(np.abs(chirp_i16))}")
print(f"Bin resolution: {FS/N:.1f} Hz, chirp bins: {int(F0*N/FS)}-{int(F1*N/FS)}")

with open(INPUT_HEX, 'w') as f:
    for v in chirp_i16:
        f.write(f"{int(v) & 0xFFFF:08x}\n")

# ── 2) numpy reference ──────────────────────────────────────────────
ref = np.fft.fft(chirp_float.astype(np.float64))
ref_mag = np.abs(ref)

# ── 3) Run the RTL simulation (full SRAM-input path) ────────────────
vvp = os.path.join(SIM_DIR, 'build', 'tb_chirp_sram.vvp')
rtl = ['fft_top.v', 'fft_core.v', 'twiddle_rom.v', 'spi_slave_proto.v', 'sram_ctrl.v']
iverilog = (['iverilog', '-g2012', '-o', vvp, '-I', RTL_DIR, 'tb_chirp_sram.v']
            + [os.path.join(RTL_DIR, f) for f in rtl] + ['ice40_stubs.v'])

print("\nBuilding + running RTL simulation (full SPI/SRAM path)...")
os.makedirs(os.path.join(SIM_DIR, 'build'), exist_ok=True)
r = subprocess.run(iverilog, cwd=SIM_DIR, capture_output=True, text=True)
if r.returncode != 0:
    print("IVERILOG FAILED:\n", r.stdout, r.stderr)
    sys.exit(1)
r = subprocess.run(['vvp', vvp], cwd=SIM_DIR, capture_output=True, text=True, timeout=600)
print(r.stdout.strip())
if r.returncode != 0 or 'ERROR' in r.stdout or 'TIMEOUT' in r.stdout:
    print("SIM FAILED:\n", r.stderr)
    sys.exit(1)

# ── 4) Read FPGA spectrum ───────────────────────────────────────────
fpga = []
with open(OUTPUT_HEX) as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        word = int(line, 16)
        re_u = word & 0xFFFF
        im_u = (word >> 16) & 0xFFFF
        re = re_u - 0x10000 if re_u >= 0x8000 else re_u
        im = im_u - 0x10000 if im_u >= 0x8000 else im_u
        fpga.append(complex(re, im))
fpga = np.array(fpga[:N])
fpga_mag = np.abs(fpga)

corr = np.corrcoef(fpga_mag, ref_mag)[0, 1]
# Scale-aligned max difference (FPGA uses block-floating-point, numpy is float).
scale = ref_mag.max() / fpga_mag.max() if fpga_mag.max() > 0 else 1.0
max_diff = np.max(np.abs(fpga_mag * scale - ref_mag))
print(f"\nCorrelation: {corr:.6f}   scaled max |Δ|: {max_diff:.1f}")

# ── 5) Plot ─────────────────────────────────────────────────────────
freq = np.arange(N) * FS / N
fig, (ax1, ax2, ax3) = plt.subplots(3, 1, figsize=(12, 10))

ax1.plot(t * 1e3, chirp_i16, linewidth=0.5)
ax1.set_xlabel('Time (ms)'); ax1.set_ylabel('Amplitude (Q1.15)')
ax1.set_title(f'Chirp {F0/1e3:.0f}-{F1/1e3:.0f} kHz, Fs={FS/1e3:.0f} kHz, N={N}')
ax1.grid(True, alpha=0.3)

ax2.plot(freq[:N//2] / 1e3, ref_mag[:N//2], 'b-', linewidth=0.7, label='NumPy float64')
ax2.axvspan(F0/1e3, F1/1e3, alpha=0.1, color='orange', label=f'{F0/1e3:.0f}-{F1/1e3:.0f} kHz')
ax2.set_xlabel('Frequency (kHz)'); ax2.set_ylabel('|X[k]|')
ax2.set_title('NumPy — Reference'); ax2.legend(); ax2.grid(True, alpha=0.3)

ax3.plot(freq[:N//2] / 1e3, fpga_mag[:N//2], 'r-', linewidth=0.7, label='FPGA sim (SRAM-staged input)')
ax3.axvspan(F0/1e3, F1/1e3, alpha=0.1, color='orange', label=f'{F0/1e3:.0f}-{F1/1e3:.0f} kHz')
ax3.set_xlabel('Frequency (kHz)'); ax3.set_ylabel('|X[k]|')
ax3.set_title('FPGA (ICE40, full SPI→SRAM→FFT→SRAM→readout) — Simulation')
ax3.legend(); ax3.grid(True, alpha=0.3)

fig.suptitle(f'Chirp FFT Comparison (SRAM-staged input path)  |  '
             f'Correlation: {corr:.6f}', fontsize=12, fontweight='bold')
plt.tight_layout()
outfile = os.path.join(SCRIPT_DIR, 'chirp_fft_comparison.png')
plt.savefig(outfile, dpi=150)
plt.close()
print(f"Plot saved: {outfile}")

if corr < 0.99:
    print(f"WARNING: correlation {corr:.4f} below 0.99 threshold")
    sys.exit(2)
print("PASS: spectrum matches numpy reference")
