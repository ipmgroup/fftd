#!/usr/bin/env python3
"""
fft_read.py — Read 64-point FFT spectrum from ICEZero FPGA via SPI.
Usage: python3 fft_read.py [--raw]
"""

import spidev
import sys
import numpy as np

N = 64

def iq15(v):
    """Q1.15 fixed-point → float (range ±1.0)"""
    if v & 0x8000:
        return -((~v & 0xFFFF) + 1) / 32767.0
    return v / 32767.0

def read_fft(spi_dev=0, cs=0, speed=200000):
    """Read 64 complex samples from FPGA via SPI."""
    spi = spidev.SpiDev()
    spi.open(spi_dev, cs)
    spi.max_speed_hz = speed
    spi.mode = 0

    data = np.zeros(N, dtype=complex)
    for i in range(N):
        rx = spi.xfer2([0, 0, 0, 0])
        w = (rx[0] << 24) | (rx[1] << 16) | (rx[2] << 8) | rx[3]
        data[i] = complex(iq15(w & 0xFFFF), iq15((w >> 16) & 0xFFFF))

    spi.close()
    return data

def main():
    raw_mode = "--raw" in sys.argv

    print(f"Reading {N}-point FFT from ICEZero...")
    fpga = read_fft()

    # Reference: NumPy FFT of ramp 0..63
    ramp = np.arange(N, dtype=np.float64)
    ref = np.fft.fft(ramp)
    mag_ref = np.abs(ref)

    mag_fpga = np.abs(fpga)
    fpga_max = np.max(mag_fpga)

    if not raw_mode:
        print(f"\n{'Bin':>4s}  {'FPGA_real':>10s}  {'FPGA_imag':>10s}  "
              f"{'FPGA_mag':>10s}  {'NumPy_mag':>10s}")
        print("-" * 58)
        for i in range(N):
            print(f"{i:4d}  {fpga[i].real:10.4f}  {fpga[i].imag:10.4f}  "
                  f"{mag_fpga[i]:10.4f}  {mag_ref[i]:10.2f}")
    else:
        for i in range(N):
            print(f"{fpga[i].real:.6f} {fpga[i].imag:.6f}")

    print(f"\nFPGA max |X|: {fpga_max:.4f}   NumPy max |X|: {np.max(mag_ref):.2f}")

    if fpga_max > 0.1:
        # Compute error vs reference
        scale = mag_ref[0] / mag_fpga[0] if mag_fpga[0] > 1e-6 else 1.0
        err = np.max(np.abs(mag_fpga * scale - mag_ref)) / np.max(mag_ref)
        print(f"DC bin: FPGA={mag_fpga[0]*scale:.2f}  NumPy={mag_ref[0]:.2f}")
        print(f"Normalized error: {err:.4f}  {'✅ OK' if err < 0.1 else '⚠️  CHECK'}")
    else:
        print("⚠️  FFT output near zero — is cap_ready LED (led3) on?")

if __name__ == "__main__":
    main()
