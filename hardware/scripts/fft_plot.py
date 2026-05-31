#!/usr/bin/env python3
"""
fft_plot.py — Spectrum plot from ICEZero FPGA FFT data.
Usage:
    python3 fft_plot.py                # interactive plot
    python3 fft_plot.py --save plot.png  # save to file
"""

import spidev
import numpy as np
import sys
import os

N = 64

def iq15(v):
    if v & 0x8000:
        return -((~v & 0xFFFF) + 1) / 32767.0
    return v / 32767.0

def read_fft():
    spi = spidev.SpiDev()
    spi.open(0, 0)
    spi.max_speed_hz = 200000
    spi.mode = 0
    data = np.zeros(N, dtype=complex)
    for i in range(N):
        rx = spi.xfer2([0, 0, 0, 0])
        w = (rx[0] << 24) | (rx[1] << 16) | (rx[2] << 8) | rx[3]
        data[i] = complex(iq15(w & 0xFFFF), iq15((w >> 16) & 0xFFFF))
    spi.close()
    return data

def main():
    import matplotlib
    # Use non-interactive backend if saving to file
    save_file = None
    for i, a in enumerate(sys.argv):
        if a == "--save" and i + 1 < len(sys.argv):
            save_file = sys.argv[i + 1]
    if save_file:
        matplotlib.use("Agg")
    else:
        matplotlib.use("TkAgg")
    import matplotlib.pyplot as plt

    print(f"Reading {N}-point FFT from ICEZero...")
    fpga = read_fft()

    # Reference
    ramp = np.arange(N, dtype=np.float64)
    ref = np.fft.fft(ramp)
    mag_ref = np.abs(ref)
    mag_fpga = np.abs(fpga)

    fpga_max = np.max(mag_fpga)
    if fpga_max < 0.01:
        print("⚠️  No FFT signal detected — check cap_ready LED")
        return 1

    # Scale FPGA to match reference
    scale = mag_ref[0] / mag_fpga[0] if mag_fpga[0] > 1e-6 else 1.0
    mag_fpga_scaled = mag_fpga * scale

    bins = np.arange(N)

    fig, axes = plt.subplots(2, 2, figsize=(13, 9))
    fig.suptitle("ICEZero 64-Point FFT — Ramp Input Spectrum", fontsize=14, fontweight="bold")

    # 1. FPGA spectrum
    ax = axes[0, 0]
    ax.stem(bins, mag_fpga_scaled, linefmt="C0-", markerfmt="C0o", basefmt="k-")
    ax.set(xlabel="Bin", ylabel="Magnitude", title="FPGA FFT (scaled)")
    ax.grid(alpha=0.3)

    # 2. NumPy reference
    ax = axes[0, 1]
    ax.stem(bins, mag_ref, linefmt="C1-", markerfmt="C1s", basefmt="k-")
    ax.set(xlabel="Bin", ylabel="Magnitude", title="NumPy FFT (reference)")
    ax.grid(alpha=0.3)

    # 3. Overlay
    ax = axes[1, 0]
    ax.stem(bins, mag_ref / np.max(mag_ref), linefmt="C1-", markerfmt="C1s",
            basefmt="k-", label="NumPy")
    ax.stem(bins, mag_fpga_scaled / np.max(mag_fpga_scaled), linefmt="C0-",
            markerfmt="C0o", basefmt="k-", label="FPGA")
    ax.set(xlabel="Bin", ylabel="Normalized", title="Overlay")
    ax.legend(); ax.grid(alpha=0.3)

    # 4. Error
    ax = axes[1, 1]
    err = mag_fpga_scaled / np.max(mag_fpga_scaled) - mag_ref / np.max(mag_ref)
    ax.stem(bins, err, linefmt="C3-", markerfmt="C3o", basefmt="k-")
    ax.axhline(y=0, color="k", linestyle="-", alpha=0.3)
    ax.set(xlabel="Bin", ylabel="Error", title=f"Max error: {np.max(np.abs(err)):.4f}")
    ax.grid(alpha=0.3)

    plt.tight_layout()

    print(f"DC bin:  FPGA={mag_fpga_scaled[0]:.2f}  NumPy={mag_ref[0]:.2f}")
    print(f"Max err: {np.max(np.abs(err)):.4f}")

    if save_file:
        plt.savefig(save_file, dpi=150, bbox_inches="tight")
        print(f"Saved: {save_file}")
    else:
        plt.show()
    return 0

if __name__ == "__main__":
    sys.exit(main())
