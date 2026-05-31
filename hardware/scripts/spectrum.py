#!/usr/bin/env python3
"""
FFT Spectrum Visualizer for ICEZero FPGA
Reads 64-point FFT result via SPI from Raspberry Pi and plots magnitude spectrum.
Compares with NumPy reference FFT.

Usage:
    python3 spectrum.py                    # read from Pi, show plot
    python3 spectrum.py --save plot.png    # save to file
    python3 spectrum.py --host rpia5.local # custom host
"""

import argparse
import sys
import subprocess
import json
import numpy as np
import os

# ── SPI data collection (runs on Pi via SSH) ──────
PI_SCRIPT = r'''
import spidev, struct, sys, os

N = 64

def iq15(v):
    """Convert Q1.15 fixed-point to float"""
    if v & 0x8000:
        return -((~v & 0xFFFF) + 1) / 32767.0
    return v / 32767.0

spi = spidev.SpiDev()
spi.open(0, 0)
spi.max_speed_hz = 200000
spi.mode = 0

re_vals = []
im_vals = []
for i in range(N):
    rx = spi.xfer2([0, 0, 0, 0])
    w = (rx[0] << 24) | (rx[1] << 16) | (rx[2] << 8) | rx[3]
    re_vals.append(iq15(w & 0xFFFF))
    im_vals.append(iq15((w >> 16) & 0xFFFF))

spi.close()

# Output as JSON for easy parsing
import json
print(json.dumps({"real": re_vals, "imag": im_vals}))
'''


def read_fft_spi(host: str, user: str = "pi") -> dict:
    """Read 64-point FFT data from FPGA via SPI on remote Pi."""
    cmd = ["ssh", f"{user}@{host}", "sudo python3 -c '{}'".format(PI_SCRIPT)]
    result = subprocess.run(cmd, capture_output=True, text=True, timeout=15)

    if result.returncode != 0:
        print(f"SSH error: {result.stderr}", file=sys.stderr)
        sys.exit(1)

    # Extract JSON from output (may have warnings mixed in)
    for line in result.stdout.strip().split("\n"):
        line = line.strip()
        if line.startswith("{"):
            return json.loads(line)

    print(f"Unexpected output: {result.stdout}", file=sys.stderr)
    sys.exit(1)


def plot_spectrum(
    fpga_data: dict,
    title: str = "ICEZero FFT Spectrum (64-point, Ramp Input)",
    save: str | None = None,
):
    """Plot FFT magnitude spectrum, comparing FPGA vs NumPy reference."""
    import matplotlib.pyplot as plt
    import matplotlib

    matplotlib.use("TkAgg")  # interactive backend

    re_fpga = np.array(fpga_data["real"], dtype=np.float64)
    im_fpga = np.array(fpga_data["imag"], dtype=np.float64)
    fpga_cplx = re_fpga + 1j * im_fpga
    mag_fpga = np.abs(fpga_cplx)

    # Reference: NumPy FFT of ramp 0..63
    ramp = np.arange(64, dtype=np.float64)
    ref = np.fft.fft(ramp)
    mag_ref = np.abs(ref)

    # Scale FPGA to match reference (FPGA uses Q1.15 which is ±1.0 range)
    # Ramp 0..63 has DC = 2016; FPGA DC should match after scaling
    if mag_fpga[0] > 1e-6:
        scale = mag_ref[0] / mag_fpga[0]
    else:
        scale = 1.0
    mag_fpga_scaled = mag_fpga * scale

    # Normalize for comparison plot
    mag_ref_norm = mag_ref / np.max(mag_ref)
    if np.max(mag_fpga_scaled) > 1e-6:
        mag_fpga_norm = mag_fpga_scaled / np.max(mag_fpga_scaled)
    else:
        mag_fpga_norm = mag_fpga_scaled

    bins = np.arange(64)

    # ── Plot ────────────────────────────────────
    fig, axes = plt.subplots(2, 2, figsize=(14, 10))
    fig.suptitle(title, fontsize=14, fontweight="bold")

    # 1. FPGA magnitude spectrum (raw)
    ax = axes[0, 0]
    ax.stem(bins, mag_fpga_scaled, linefmt="C0-", markerfmt="C0o", basefmt="k-")
    ax.set_xlabel("Frequency Bin")
    ax.set_ylabel("Magnitude (scaled)")
    ax.set_title("FPGA FFT — Magnitude Spectrum")
    ax.grid(True, alpha=0.3)
    ax.set_xlim(-0.5, 63.5)

    # 2. NumPy reference
    ax = axes[0, 1]
    ax.stem(bins, mag_ref, linefmt="C1-", markerfmt="C1s", basefmt="k-")
    ax.set_xlabel("Frequency Bin")
    ax.set_ylabel("Magnitude")
    ax.set_title("NumPy FFT — Reference")
    ax.grid(True, alpha=0.3)
    ax.set_xlim(-0.5, 63.5)

    # 3. Overlay comparison (normalized)
    ax = axes[1, 0]
    ax.stem(bins, mag_ref_norm, linefmt="C1-", markerfmt="C1s",
            basefmt="k-", label="NumPy (ref)")
    ax.stem(bins, mag_fpga_norm, linefmt="C0-", markerfmt="C0o",
            basefmt="k-", label="FPGA")
    ax.set_xlabel("Frequency Bin")
    ax.set_ylabel("Normalized Magnitude")
    ax.set_title("FPGA vs NumPy — Overlay")
    ax.legend(loc="upper right")
    ax.grid(True, alpha=0.3)
    ax.set_xlim(-0.5, 63.5)

    # 4. Error (difference)
    ax = axes[1, 1]
    error = mag_fpga_norm - mag_ref_norm
    ax.stem(bins, error, linefmt="C3-", markerfmt="C3o", basefmt="k-")
    ax.axhline(y=0, color="k", linestyle="-", alpha=0.3)
    ax.set_xlabel("Frequency Bin")
    ax.set_ylabel("Normalized Error")
    ax.set_title(f"Error (max={np.max(np.abs(error)):.4f})")
    ax.grid(True, alpha=0.3)
    ax.set_xlim(-0.5, 63.5)

    plt.tight_layout()

    if save:
        plt.savefig(save, dpi=150, bbox_inches="tight")
        print(f"Saved: {save}")

    plt.show()

    # ── Text summary ────────────────────────────
    print(f"\n{'='*50}")
    print(f"DC bin (0):    FPGA={mag_fpga_scaled[0]:.2f}  NumPy={mag_ref[0]:.2f}")
    print(f"Max magnitude: FPGA={np.max(mag_fpga_scaled):.2f}  "
          f"NumPy={np.max(mag_ref):.2f}")
    print(f"Scale factor:  {scale:.6f}")
    if np.max(mag_fpga_scaled) > 0.1:
        print("✅ FFT output detected!")
    else:
        print("⚠️  FFT output near zero — check capture buffer")
    print(f"{'='*50}")


def main():
    parser = argparse.ArgumentParser(
        description="ICEZero FFT Spectrum Visualizer")
    parser.add_argument("--host", default="rpia5.local",
                        help="Raspberry Pi hostname/IP (default: rpia5.local)")
    parser.add_argument("--user", default="pi",
                        help="SSH username (default: pi)")
    parser.add_argument("--save", default=None,
                        help="Save plot to file (e.g. spectrum.png)")
    parser.add_argument("--title", default=None,
                        help="Plot title")
    args = parser.parse_args()

    print(f"📡 Reading FFT data from {args.host} via SPI...")
    data = read_fft_spi(args.host, args.user)

    print(f"📊 Got {len(data['real'])} complex samples")

    title = args.title or "ICEZero FFT Spectrum (64-point, Ramp Input)"
    plot_spectrum(data, title=title, save=args.save)


if __name__ == "__main__":
    main()
