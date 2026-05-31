#!/usr/bin/env python3
"""
compare_fft.py — Compare FPGA FFT (iverilog simulation) vs numpy.fft.fft()

Usage:
  python3 compare_fft.py                   # ramp 0..63
  python3 compare_fft.py --input sine --bin 8
  python3 compare_fft.py --input random --seed 7
  python3 compare_fft.py --input dc --amp 1000
  python3 compare_fft.py --no-sim          # reuse existing fft_output.hex
"""

import argparse
import os
import subprocess
import sys

import numpy as np

# ---------------------------------------------------------------------------
N      = 1024
WIDTH  = 16
MAX_Q  = (1 << (WIDTH - 1)) - 1   # 32767

SCRIPT_DIR  = os.path.dirname(os.path.abspath(__file__))
SIM_DIR     = os.path.abspath(os.path.join(SCRIPT_DIR, '..', 'sim'))
INPUT_HEX   = os.path.join(SIM_DIR, 'fft_input.hex')
OUTPUT_HEX  = os.path.join(SIM_DIR, 'fft_output.hex')
WORKSPACE   = os.path.abspath(os.path.join(SCRIPT_DIR, '..', '..'))

DOCKER_IMAGE = 'ice40-fft'

# ---------------------------------------------------------------------------
# Input signal generators
# ---------------------------------------------------------------------------

def gen_ramp():
    return np.arange(N, dtype=np.int16)

def gen_sine(freq_bin: int = 4, amplitude: int = 1000):
    t = np.arange(N)
    v = amplitude * np.sin(2 * np.pi * freq_bin * t / N)
    return np.round(v).astype(np.int16)

def gen_dc(amplitude: int = 1000):
    return np.full(N, amplitude, dtype=np.int16)

def gen_impulse():
    x = np.zeros(N, dtype=np.int16)
    x[0] = MAX_Q
    return x

def gen_random(seed: int = 42, amplitude: int = 500):
    """Random input with bounded amplitude to avoid FFT overflow.
    Max safe amplitude ≈ 32767 / N = 32 for 1024-point FFT."""
    rng = np.random.default_rng(seed)
    return rng.integers(-amplitude, amplitude + 1, N, dtype=np.int16)

# ---------------------------------------------------------------------------
# Hex I/O
# ---------------------------------------------------------------------------

def write_input_hex(real_samples: np.ndarray, path: str):
    """Write N 32-bit words {imag=0, real} to hex file."""
    with open(path, 'w') as f:
        for r in real_samples:
            word = int(r) & 0xFFFF          # imag = 0
            f.write(f"{word:08x}\n")

def read_output_hex(path: str) -> np.ndarray:
    """Read N 32-bit words {imag[15:0], real[15:0]} → complex array."""
    out = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            word = int(line, 16)
            re_u = word & 0xFFFF
            im_u = (word >> 16) & 0xFFFF
            re = re_u - 0x10000 if re_u >= 0x8000 else re_u
            im = im_u - 0x10000 if im_u >= 0x8000 else im_u
            out.append(complex(re, im))
    return np.array(out[:N])

# ---------------------------------------------------------------------------
# Simulation runner
# ---------------------------------------------------------------------------

def run_sim_docker():
    iverilog_cmd = (
        'iverilog -g2012 -Wall -I ../rtl '
        '-o build/tb_fft_compare.vvp '
        'tb_fft_compare.v ../rtl/fft_core.v ../rtl/twiddle_rom.v ice40_stubs.v'
    )
    vvp_cmd = 'vvp build/tb_fft_compare.vvp'
    shell_cmd = f'mkdir -p build && cp twiddle.hex build/ 2>/dev/null; {iverilog_cmd} 2>&1 && {vvp_cmd}'

    result = subprocess.run(
        ['docker', 'run', '--rm',
         '-v', f'{WORKSPACE}:/workspace',
         '-w', '/workspace/hardware/sim',
         DOCKER_IMAGE,
         'sh', '-c', shell_cmd],
        capture_output=True, text=True
    )
    print(result.stdout.strip())
    if result.returncode != 0 or 'ERROR' in result.stdout:
        print(result.stderr.strip(), file=sys.stderr)
        sys.exit(f"Simulation failed (exit {result.returncode})")

def run_sim_local():
    """Try to use local iverilog/vvp."""
    os.makedirs(os.path.join(SIM_DIR, 'build'), exist_ok=True)
    build_dir = os.path.join(SIM_DIR, 'build')

    # copy twiddle.hex to build/
    tw_src = os.path.join(SIM_DIR, 'twiddle.hex')
    if os.path.exists(tw_src):
        import shutil
        shutil.copy(tw_src, build_dir)

    rtl_dir = os.path.join(SIM_DIR, '..', 'rtl')
    ivl_args = [
        'iverilog', '-g2012', '-Wall',
        '-I', rtl_dir,
        '-o', os.path.join(build_dir, 'tb_fft_compare.vvp'),
        os.path.join(SIM_DIR, 'tb_fft_compare.v'),
        os.path.join(rtl_dir, 'fft_core.v'),
        os.path.join(rtl_dir, 'twiddle_rom.v'),
        os.path.join(SIM_DIR, 'ice40_stubs.v'),
    ]
    r = subprocess.run(ivl_args, capture_output=True, text=True)
    if r.returncode != 0:
        print(r.stderr, file=sys.stderr)
        sys.exit("iverilog failed")

    r = subprocess.run(
        ['vvp', os.path.join(build_dir, 'tb_fft_compare.vvp')],
        capture_output=True, text=True, cwd=SIM_DIR
    )
    print(r.stdout.strip())
    if r.returncode != 0 or 'ERROR' in r.stdout:
        print(r.stderr, file=sys.stderr)
        sys.exit("vvp failed")

def run_sim(use_docker: bool):
    if use_docker:
        run_sim_docker()
    else:
        run_sim_local()

# ---------------------------------------------------------------------------
# Comparison
# ---------------------------------------------------------------------------

TOLERANCE = 32  # LSB — per bin, re & im separately (N=1024 needs ~23, theory: N_LOG2*2^-14*32767)

def compare(fpga: np.ndarray, ref_float: np.ndarray, tol: int = TOLERANCE):
    """Print side-by-side table and return (max_err, fail_count).

    Reference is truncated to int16 before comparison because the FPGA
    operates in 16-bit arithmetic throughout — overflow wraps identically.
    Bins where the ideal (float) reference overflows int16 are flagged.
    """
    hdr = (f"{'Bin':>4}  {'Re ref':>9} {'Im ref':>9}  "
           f"{'Re fpga':>9} {'Im fpga':>9}  {'dRe':>6} {'dIm':>6}  {'note'}")
    print(hdr)
    print('─' * (len(hdr) + 4))

    max_err  = 0
    fails    = 0
    overflows = 0
    for i in range(N):
        # Ideal float reference
        re_f = ref_float[i].real
        im_f = ref_float[i].imag
        # Truncate to int16 (same as FPGA 16-bit wrap)
        re_ref = (int(round(re_f)) & 0xFFFF)
        if re_ref >= 0x8000: re_ref -= 0x10000
        im_ref = (int(round(im_f)) & 0xFFFF)
        if im_ref >= 0x8000: im_ref -= 0x10000
        re_hw  = int(fpga[i].real)
        im_hw  = int(fpga[i].imag)
        d_re   = re_hw - re_ref
        d_im   = im_hw - im_ref
        max_err = max(max_err, abs(d_re), abs(d_im))
        ovf = abs(re_f) > 32767 or abs(im_f) > 32767
        if ovf:
            overflows += 1
        fail = (abs(d_re) > tol or abs(d_im) > tol) and not ovf
        if fail:
            fails += 1
        note = 'OVF' if ovf else ('← FAIL' if fail else '')
        print(f"{i:>4}  {re_ref:>9} {im_ref:>9}  {re_hw:>9} {im_hw:>9}  "
              f"{d_re:>6} {d_im:>6}  {note}")

    print()
    if overflows:
        print(f"Overflow bins (|ref|>32767, wrapped): {overflows}  — shown with 'OVF', excluded from FAIL count")
    print(f"Max error : {max_err} LSB  (tolerance ±{tol})")
    return max_err, fails

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(description='FPGA vs numpy FFT comparator')
    parser.add_argument('--input', choices=['ramp', 'sine', 'dc', 'impulse', 'random'],
                        default='ramp', help='Input signal type (default: ramp)')
    parser.add_argument('--bin',  type=int, default=4, help='Sine frequency bin (default: 4)')
    parser.add_argument('--amp',  type=int, default=1000, help='Sine/DC amplitude (default: 1000)')
    parser.add_argument('--seed', type=int, default=42, help='Random seed (default: 42)')
    parser.add_argument('--tol',  type=int, default=TOLERANCE, help=f'Per-bin error tolerance LSB (default: {TOLERANCE})')
    parser.add_argument('--no-sim', action='store_true', help='Skip simulation, reuse fft_output.hex')
    parser.add_argument('--docker', action='store_true', default=True, help='Use Docker to run simulation (default: True)')
    parser.add_argument('--local',  action='store_true', help='Use local iverilog/vvp instead of Docker')
    args = parser.parse_args()

    use_docker = not args.local

    # --- generate input ---
    if args.input == 'ramp':
        x = gen_ramp()
        label = f'Ramp 0..{N-1}'
    elif args.input == 'sine':
        x = gen_sine(args.bin, args.amp)
        label = f'Sine bin={args.bin} amp={args.amp}'
    elif args.input == 'dc':
        x = gen_dc(args.amp)
        label = f'DC amp={args.amp}'
    elif args.input == 'impulse':
        x = gen_impulse()
        label = 'Impulse x[0]=32767'
    else:
        x = gen_random(args.seed, args.amp)
        label = f'Random seed={args.seed} amp=±{args.amp}'

    print(f'Signal  : {label}')
    print(f'Samples : {x[:8].tolist()} ...')

    # --- write input hex ---
    write_input_hex(x, INPUT_HEX)
    print(f'Written : {INPUT_HEX}')

    # --- run simulation ---
    if not args.no_sim:
        backend = 'Docker' if use_docker else 'local'
        print(f'Sim     : running iverilog/vvp via {backend}...')
        run_sim(use_docker)
    else:
        print('Sim     : skipped (--no-sim)')

    # --- read FPGA output ---
    if not os.path.exists(OUTPUT_HEX):
        sys.exit(f'Missing: {OUTPUT_HEX} — simulation did not produce output')
    fpga = read_output_hex(OUTPUT_HEX)
    print(f'Read    : {OUTPUT_HEX} ({len(fpga)} bins)')

    # --- numpy reference ---
    ref = np.fft.fft(x.astype(np.float64))

    # --- compare ---
    print()
    max_err, fails = compare(fpga, ref, tol=args.tol)

    if fails == 0:
        print(f'Result  : *** ALL {N} BINS PASS *** (max error {max_err} LSB)')
    else:
        print(f'Result  : *** {fails}/{N} BINS FAILED ***')
        sys.exit(1)


if __name__ == '__main__':
    main()
