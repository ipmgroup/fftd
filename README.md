# ICE40 FFT — FPGA-Accelerated FFT for Linux

Hardware-accelerated Fast Fourier Transform on Lattice ICE40HX4K FPGA with Linux kernel driver and FFTW-compatible user-space API.

## Overview

This project provides an end-to-end DSP pipeline: from Verilog RTL running on an ICEZero board to a Linux `libfft.so` library with Python bindings — all built with the fully open-source Project IceStorm toolchain.

- **FPGA**: Lattice ICE40HX4K (3520 LUT4, 80 kbit BRAM)
- **Board**: Trenz Electronic ICEZero (Raspberry Pi HAT form-factor)
- **FFT sizes**: 32 / 64 / 128 points, configurable at runtime
- **Data width**: 12–16 bit input, 16–20 bit output
- **Throughput**: up to 10 MSPS
- **Latency**: < 100 µs (64-point FFT at 50 MHz)
- **Driver**: UIO-based Linux kernel module (`/dev/fft_0`)
- **API**: FFTW-compatible C library + Python bindings

## Quick Start

### Docker (recommended — no local toolchain needed)

```bash
git clone https://github.com/ipmgroup/fftd.git
cd fftd

# Build Docker image & run blinky test
make docker-build
make docker-blinky

# Interactive shell
make docker-shell
```

### Native (requires toolchain installation)

```bash
# Install toolchain
./scripts/setup_dev.sh

# Build everything (sim, synth, kernel driver, user lib)
make all

# 4. Deploy to Raspberry Pi + ICEZero
echo "rpia5" > .config/pi_address.txt
./scripts/deploy_to_pi.sh

# 5. Run integration tests
./scripts/test_on_pi.sh
```

## Repository Structure

```
ice40-fft/
├── hardware/           # Verilog RTL, testbenches, synthesis scripts
│   ├── rtl/            # fft_core, axi_lite, fifo, uart, gpio, top
│   ├── sim/            # iverilog/Verilator testbenches
│   └── synth/          # Yosys + nextpnr + pin constraints (.pcf)
├── software/
│   ├── kernel_driver/  # Linux kernel module (UIO)
│   ├── lib/            # libfft.so — C library, FFTW-compatible
│   ├── python/         # pyfft — Python ctypes wrapper
│   └── utils/          # fft_load, fft_test, fft_profile
├── examples/           # C and Python usage examples
├── tests/              # Unit + integration tests (pytest)
├── scripts/            # dev setup, deploy, remote test scripts
└── docs/               # Architecture, API, setup guides
```

## API (C)

```c
#include <fft.h>

fft_handle_t *h = fft_init(64);           // 64-point FFT
fft_compute_forward(h, input, output);     // complex → complex
fft_compute_inverse(h, input, output);     // complex → complex
fft_get_config(h, &cfg);
fft_destroy(h);
```

## API (Python)

```python
from pyfft import FFT

fft = FFT(size=64)
spectrum = fft.forward(data)      # numpy-compatible
reconstructed = fft.inverse(spectrum)
```

## Requirements

| Component | Version |
|-----------|---------|
| Yosys | ≥ 0.30 |
| nextpnr-ice40 | ≥ 0.40 |
| Python | ≥ 3.8 |
| GCC | ≥ 9.0 |
| Linux kernel | ≥ 5.10 (arm64 on Raspberry Pi) |

## Hardware

- **ICEZero board** (TE0876-03-A) — $25
- **Raspberry Pi 4/5** — host controller (SPI programming + data exchange via GPIO)
- Total BOM: ~$90

## Development Workflow

```
Dev PC (x86_64)                    Raspberry Pi + ICEZero (HAT)
─────────────                      ─────────────────────────────
  edit → sim → synth      scp/ssh    iceprog (SPI via GPIO)
  cross-compile driver ──────────→  insmod fft_driver.ko
  cross-compile lib    ──────────→  run tests & profile
```

The ICEZero board mounts directly on the Raspberry Pi's 40-pin GPIO header (HAT form-factor). All communication — bitstream loading, register access, and data transfer — happens over SPI (32 MHz Mesa Bus Protocol). No USB or external programmers required.

## License

MIT — see [LICENSE](LICENSE) file.

---

Built with [Project IceStorm](http://www.clifford.at/icestorm/) — the fully open-source FPGA toolchain.
