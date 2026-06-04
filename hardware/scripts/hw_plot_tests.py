#!/usr/bin/env python3
"""
hw_plot_tests.py — Per-signal FFT plots from the REAL FPGA (iceZero/RPi).

For each test signal (DC, ramp, sin, chirp) this stages a frame into the
FPGA, runs the hardware FFT, and saves a PNG comparing the hardware spectrum
against a numpy reference, all collected in the plot/ directory:

    plot/<signal>_hw_comparison.png   (time-domain input + normalized spectrum)

Both input paths are exercised: BRAM (WRITE_DATA 0x41) and SRAM-staged
(WRITE_SRAM 0x43); the FPGA curve plotted is the BRAM path and the title
reports the magnitude correlation of both paths vs numpy.

Run on the Pi (after flashing the bitstream):
    python3 hardware/scripts/hw_plot_tests.py
"""

import sys, os, time, numpy as np
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from fft_proto import FftProto, CTRL_START

N         = 1024
FS        = 100e3
OUTDIR    = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'plot')


def make_signals():
    n = np.arange(N)
    sigs = {}
    sigs['DC']    = np.full(N, 1000, dtype=np.int16)
    sigs['ramp']  = (n % N).astype(np.int16)
    sigs['sin']   = np.round(1000 * np.sin(2*np.pi*100*n/N)).astype(np.int16)
    t = n / FS
    chirp = np.sin(2*np.pi*(18e3*t + (34e3-18e3)*t**2/(2*t[-1])))
    sigs['chirp'] = np.round(60 * chirp).astype(np.int16)
    return sigs


def run_one(proto, samples, use_sram):
    samples = samples.astype(np.float64)
    err = proto.write_data_sram(samples) if use_sram else proto.write_data(samples)
    if err:
        return None, f"write error: {err}"
    time.sleep(0.02)
    proto.control(CTRL_START)
    if not proto.wait_done(timeout=5.0, poll_ms=20):
        return None, "FFT timeout"
    bins, err = proto.bulk_read(N, rescale=True, hermitian=True)
    if err:
        return None, f"read error: {err}"
    return bins, None


def main():
    os.makedirs(OUTDIR, exist_ok=True)
    sigs = make_signals()
    proto = FftProto()

    flags, err = proto.status()
    if err:
        print(f"STATUS error: {err} — is the bitstream flashed?")
        sys.exit(1)
    print(f"STATUS: ready={flags['ready']} busy={flags['busy']} done={flags['done']}\n")

    freq = np.fft.fftfreq(N, 1.0 / FS) / 1e3       # kHz
    half = N // 2
    n_idx = np.arange(N)

    for name, s in sigs.items():
        ref = np.fft.fft(s.astype(np.float64))
        ref_mag = np.abs(ref)

        bram, e1 = run_one(proto, s, use_sram=False)
        sram, e2 = run_one(proto, s, use_sram=True)
        if e1:
            print(f"{name:>5s}  BRAM FAIL: {e1}")
            continue

        fpga_mag = np.abs(bram)
        corr_bram = np.corrcoef(fpga_mag, ref_mag)[0, 1]
        corr_sram = (np.corrcoef(np.abs(sram), ref_mag)[0, 1]
                     if e2 is None else float('nan'))

        ref_n  = ref_mag  / ref_mag.max()  if ref_mag.max()  > 0 else ref_mag
        fpga_n = fpga_mag / fpga_mag.max() if fpga_mag.max() > 0 else fpga_mag

        fig, (ax1, ax2) = plt.subplots(2, 1, figsize=(11, 7))

        ax1.plot(n_idx, s, 'k-', linewidth=0.7)
        ax1.set_xlabel('sample'); ax1.set_ylabel('amplitude')
        ax1.set_title(f'{name} — time-domain input (N={N})')
        ax1.grid(True, alpha=0.3); ax1.set_xlim(0, N - 1)

        ax2.plot(freq[:half], ref_n[:half],  'b-',  linewidth=1.0, label='NumPy float64 (ref)')
        ax2.plot(freq[:half], fpga_n[:half], 'r--', linewidth=1.0, label='FPGA (ICE40, BRAM path)')
        ax2.set_xlabel('frequency (kHz)'); ax2.set_ylabel('normalized |X|')
        ax2.set_title('Spectrum: FPGA vs NumPy (peak-normalized)')
        ax2.legend(); ax2.grid(True, alpha=0.3); ax2.set_xlim(0, FS / 2e3)

        fig.suptitle(f'FFT hardware test: {name}   |   '
                     f'corr(BRAM)={corr_bram:.6f}   corr(SRAM)={corr_sram:.6f}',
                     fontsize=12)
        fig.tight_layout(rect=[0, 0, 1, 0.96])
        out = os.path.join(OUTDIR, f'{name.lower()}_hw_comparison.png')
        fig.savefig(out, dpi=150)
        plt.close(fig)
        print(f"{name:>5s}  corr(BRAM)={corr_bram:.6f}  corr(SRAM)={corr_sram:.6f}  ->  {out}")

    proto.close()
    print(f"\nPlots written to {OUTDIR}/")


if __name__ == '__main__':
    main()
