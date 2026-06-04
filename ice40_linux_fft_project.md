# Technical Specification

## FPGA DSP System with FFT Accelerator based on ICE40HX4K for Linux

**Version**: 1.0  
**Date**: 2026-05-30  

---

> **As-built note (2026-06-04).** This document is the original design spec.
> The implemented system differs in a few key points; see `README.md` and
> `fft_spi_protocol_doc.md` for current details:
> - **Clocking is dual-domain**: SPI slave at 87.5 MHz, FFT core at 43.75 MHz
>   (one `SB_PLL40_2F_PAD`, CDC between them) — not a single 50 MHz domain.
>   The core clock is LUT-multiplier-bound (~73 MHz Fmax; ICE40HX has no DSP).
> - **SPI SCK** is reliable up to **14 MHz** (re-measured bit-exact; 15 MHz+ drops bits).
>   `BULK_READ` (0x23) streams the whole spectrum in one transaction (~1.27× faster readout).
> - **External SRAM is used as a result double-buffer**: results are copied
>   BRAM→SRAM each frame, so the host streams frame *N* while the core computes
>   frame *N+1*. A pipelined host loop reaches **~2.0× throughput** (~500 FFT/s).
> - **External SRAM is also an input double-buffer**: `WRITE_SRAM` (0x43) stages
>   the next input frame into SRAM while the core is busy/being read out; a START
>   triggers an input-DMA (SRAM→BRAM) before the FFT runs. A priority FIFO drains
>   host writes between output-DMA bins so samples are never dropped.
> - **FFT output is complex** (re+im, 4 bytes/bin) with a block-floating-point
>   exponent in the STATUS byte — not real-only, 2 bytes/bin.
> - The 1024-point pipeline is the validated configuration. Verified on hardware
>   (DC/ramp/sin correlate 1.000000 with NumPy, chirp 0.999987) through **both**
>   the direct BRAM (0x41) and SRAM-staged (0x43) input paths.

---

## Terms, Definitions and Abbreviations

| Term | Definition |
|--------|------------|
| **AXI Lite** | Lightweight subset of AMBA AXI4 protocol for memory-mapped master-slave connections |
| **BRAM** | Block RAM — FPGA on-chip block memory |
| **DFT** | Discrete Fourier Transform |
| **DSP** | Digital Signal Processing |
| **FFT** | Fast Fourier Transform |
| **FIFO** | First In, First Out — hardware queue |
| **FPGA** | Field-Programmable Gate Array |
| **FTE** | Full-Time Equivalent |
| **HAT** | Hardware Attached on Top — Raspberry Pi expansion board |
| **LUT** | Look-Up Table — basic FPGA logic element |
| **MTBF** | Mean Time Between Failures |
| **PIO** | Programmed Input/Output |
| **PMOD** | Digilent peripheral module standard (6-pin connector) |
| **RTL** | Register Transfer Level |
| **SDFT** | Sliding Discrete Fourier Transform |
| **UIO** | Userspace I/O — Linux framework for user-space drivers |

---

## 1. General Provisions

### 1.1 Project Purpose

Development of an embedded digital signal processing system based on ICE40HX4K FPGA with hardware FFT acceleration and Linux integration via kernel driver and user-space library.

### 1.2 Target Platform

**Hardware:**
- **Board**: Trenz Electronic ICEZero (TE0876-03-A)
- **FPGA**: Lattice ICE40HX4K-TQ144 (3520 LUT4, 80 kbits Block RAM, 40 nm)
- **Memory**: 
  - 4 Mbit external SRAM (IS61WV25616BLL-10TLI, 256K×16, 10 ns, 512 kBytes)
  - 8 MByte QSPI Flash (for bitstream)
  - 2 kbit EEPROM
- **GPIO**: 
  - 32 x I/O (4 x PMOD connectors, 6 pin each)
  - 4 x GPIO (FTDI Pin Header)
  - 5 x GPIO (Pin Header)
- **On-Board components**:
  - Push Button (user input)
  - 3 x user LEDs (status/debug)
  - 100 MHz oscillator (clock source)
- **Power**: 5V from Raspberry Pi (via 2x20 HAT connector)
- **Size**: 30.5 x 65 mm (Raspberry Pi HAT compatible)
- **Interfaces**: Raspberry Pi standard GPIO header, PMOD-compatible connectors

**Software and Tools:**
- **Toolchain**: Project IceStorm (fully open source)
  - Yosys (synthesis)
  - nextpnr (place & route)
  - icepack (bitstream generation)
  - iceprog (programming)
- **OS**: Linux (kernel 5.10+, arm64 on Raspberry Pi, x86_64 for development)
- **Language**: Verilog (for RTL)

### 1.3 Application Domain

Real-time signal processing, spectral analysis, DSP algorithm prototyping, educational projects.

### 1.4 Development Workflow

**Development Machine**: Linux (x86_64)
- HDL synthesis and simulation (Yosys, iverilog, Verilator)
- Cross-compilation C/Python for ARM (gcc-arm-linux-gnueabihf)
- Build kernel driver and user-space lib
- Unit tests and integration tests (including mock FPGA)

**Target Hardware**: Raspberry Pi + ICEZero
- SSH access for remote development
- `scp` for bitstream and binary upload
- `ssh` for test execution and debugging
- `sshfs` optional for remote mounting

**Workflow**:
```
┌─────────────────────────────────────────┐
│  Development Linux PC (x86_64)          │
├─────────────────────────────────────────┤
│ o Editing (VSCode, vim, etc.)          │
│ o Synthesis (Yosys, nextpnr)           │
│ o Simulation (iverilog, Verilator)     │
│ o Build (gcc for ARM, cross-compile)   │
│ o Unit tests (pytest, gtest)           │
│ o Generate bitstream (.bin)            │
│ o Cross-compile kernel driver          │
│ o Cross-compile user-space lib/apps    │
└──────────┬──────────────────────────────┘
           │ scp/ssh (over network)
           │
┌──────────▼──────────────────────────────┐
│  Raspberry Pi 4/5 + ICEZero             │
├─────────────────────────────────────────┤
│ o Load bitstream (iceprog)              │
│ o Load kernel driver (insmod)           │
│ o Run integration tests                 │
│ o Profile performance                   │
│ o Debug via serial/SSH                  │
└─────────────────────────────────────────┘
```

---

## 2. Requirements

### 2.1 Functional Requirements

#### 2.1.1 FPGA Component

| Requirement | Specification |
|-----------|-------------|
| **FFT size** | 32-point, 64-point, 128-point FFT (configurable) |
| **Algorithm** | Cooley-Tukey, DFT pipelined or Sliding DFT |
| **Data width** | 12-16 bit input, 16-20 bit output |
| **Throughput** | 1-10 MSPS depending on FFT size |
| **Interfaces** | AXI Lite / native memory-mapped I/O |
| **Additional** | Window function (Hann), output scaling |

#### 2.1.2 FPGA Peripherals

- **UART**: 115200 bps for debugging via PMOD connector (optional: via FTDI Pin Header — 4 GPIO pins on board)
- **SPI Slave**: 8 MHz, custom protocol for Raspberry Pi communication
- **GPIO**: 8+ pins (on PMOD connectors) for LEDs, buttons, PWM
- **I2C**: Optional via PMOD (2 pins for SDA/SCL)

#### 2.1.3 Linux Components

| Component | Requirement |
|-----------|-----------|
| **Kernel driver** | UIO-based or misc device driver |
| **User-space library** | C/Python API, FFTW-compatible interface |
| **Utilities** | `fft_load`, `fft_test`, `fft_profile` |
| **Documentation** | API docs, code examples, README |

#### 2.1.4 Integration

- Bitstream loading via SPI from Raspberry Pi (`iceprog`)
- FFT register access via SPI (custom protocol, 8 MHz)
- Data transfer: PIO via SPI (DMA not supported by ICE40HX)
- Result interpretation on Raspberry Pi (Python/C)

### 2.2 Non-Functional Requirements

#### 2.2.1 Performance

- **FFT Latency**: < 100 us for 64-point FFT
- **Guaranteed clock**: 50 MHz (ICE40HX speed grade 5)
- **Peak power**: < 500 mW

#### 2.2.2 Reliability and Debugging

- Formal verification for critical modules (butterfly, twiddle ROM)
- Simulation of all components (iverilog/verilator)
- Testbench with NumPy FFT comparison
- Error and overflow handling

#### 2.2.3 Scalability

- Parameterized FFT size (16, 32, 64, 128 points)
- Support for different bitwidth configurations
- Future expandability (SDFT, real FFT)

#### 2.2.4 Compatibility

- Open source toolchain (Project IceStorm)
- Verilog/VHDL + Python for generation
- Linux kernel 5.10+
- GCC, GDB support for debugging

### 2.3 Power Requirements

| Parameter | Value | Notes |
|----------|----------|------------|
| Input voltage | 5.0 V +/- 5% | From Raspberry Pi via HAT connector |
| Peak current | <= 150 mA | Total FPGA + SRAM + peripherals |
| Peak power | <= 500 mW | Excluding Raspberry Pi power |
| Overcurrent protection | 500 mA fuse (on ICEZero board) |
| Inrush current | <= 300 mA for <= 10 ms |
| Power supply noise | <= 50 mV (peak-to-peak) on 5V line |
| Backup power | Optional: external 5V via Micro-USB |

### 2.4 Environmental Requirements

| Parameter | Range | Notes |
|----------|----------|------------|
| Operating ambient temperature | 0...+70 degC | ICE40HX commercial range |
| Storage temperature | -40...+100 degC | |
| Operating relative humidity | 10...90 % | Non-condensing |
| Atmospheric pressure | 84...107 kPa | |
| ESD protection | +/-2 kV (HBM) | JESD22-A114 standard |
| Vibration | Not specified (laboratory use) | |

### 2.5 Reliability Requirements

| Parameter | Value |
|----------|----------|
| Mean Time Between Failures (MTBF) | >= 50,000 hours (calculated) |
| Service life | >= 5 years |
| QSPI Flash write cycles | >= 100,000 |
| FPGA reload cycles | >= 10,000 |
| Recovery time after failure | <= 5 seconds (driver reload + reprogramming) |
| Self-diagnostics | Built-in FIFO and control register test at initialization |

### 2.6 IP Purity Requirements

- All software components distributed under open licenses (MIT, BSD, GPLv2, Apache 2.0)
- FFT accelerator RTL code is original development or uses blocks with confirmed open license
- No proprietary IP cores requiring license fees
- Project IceStorm (Yosys, nextpnr, icepack) distributed under ISC license (permissive)

---

## 3. System Architecture

### 3.1 Block Diagram

```
┌─────────────────────────────────────────┐
│      Raspberry Pi + ICEZero (HAT)       │
├─────────────────────────────────────────┤
│  User-space App (Python/C)              │
│  +-- libfft.so (FFTW-compatible API)    │
├─────────────────────────────────────────┤
│  Linux Kernel                           │
│  +-- fft_driver.ko (UIO/misc driver)    │
│       +-- SPI subsystem (spidev)         │
├─────────────────────────────────────────┤
│   2x20 GPIO HAT Connector               │
│   +-- SPI0 (MOSI,MISO,SCLK,CE0) 8 MHz  │
│   +-- 5V power                           │
│   +-- GPIO control/status                │
└──────────┬──────────────────────────────┘
           │ SPI (Custom Protocol)
           │
┌──────────▼──────────────────────────────┐
│     ICEZero Board (ICE40HX4K)           │
├──────────────────────────────────────────┤
│  ┌──────────────────────────────────┐   │
│  │  FFT Accelerator Module          │   │
│  │  ┌─────────────────────────────┐ │   │
│  │  │ AXI Lite Slave Interface    │ │   │
│  │  └──────┬──────────────────────┘ │   │
│  │         │                        │   │
│  │  ┌──────▼──────────────────────┐ │   │
│  │  │ Control Registers (16 regs) │ │   │
│  │  │ Status, Config, IRQ masks   │ │   │
│  │  └──────────────────────────────┘ │   │
│  │         │                        │   │
│  │  ┌──────▼──────────────────────┐ │   │
│  │  │ Input Data FIFO (256 bytes) │ │   │
│  │  └──────────────────────────────┘ │   │
│  │         │                        │   │
│  │  ┌──────▼──────────────────────┐ │   │
│  │  │ FFT Engine (pipelined)      │ │   │
│  │  │ o Butterfly stages          │ │   │
│  │  │ o Twiddle ROM (parameterized)│   │
│  │  │ o Bit-reverser              │ │   │
│  │  │ o Scaling/Windowing         │ │   │
│  │  └──────────────────────────────┘ │   │
│  │         │                        │   │
│  │  ┌──────▼──────────────────────┐ │   │
│  │  │ Output Data FIFO (256 bytes) │ │   │
│  │  └──────────────────────────────┘ │   │
│  └──────────────────────────────────┘   │
│                                          │
│  ┌──────────────────────────────────┐   │
│  │ SPI Slave (8 MHz)                │   │
│  │ +-- Register access (read/write) │   │
│  │ +-- Bitstream loading            │   │
│  │ +-- PIO data transfer            │   │
│  └──────────────────────────────────┘   │
│                                          │
│  ┌──────────────────────────────────┐   │
│  │ Peripheral Bus (memory-mapped)   │   │
│  │ +-- UART Controller (PMOD)       │   │
│  │ +-- GPIO Controller (8 pins)     │   │
│  │ +-- SRAM Controller (4 Mbit)     │   │
│  └──────────────────────────────────┘   │
└──────────────────────────────────────────┘
```

### 3.2 FPGA Components

| Module | Purpose | LUT | BRAM | Notes |
|--------|-----------|-----|------|-----------|
| `fft_engine` | Main FFT accelerator | 1000-1200 | 40 | Generator-based, opt. for HX4K |
| `axi_lite_slave` | AXI Lite interface | 120 | 0 | Controller, status |
| `fifo_input` | Input buffer | 60 | 4 | 256 bytes |
| `fifo_output` | Output buffer | 60 | 4 | 256 bytes |
| `uart_ctrl` | UART controller | 100 | 0 | 115200 bps (optional) |
| `gpio_ctrl` | GPIO controller | 60 | 0 | 8 pins |
| `sram_controller` | SRAM controller | 150 | 0 | 4M SRAM available |
| **Total (max)** | | **1800-2000** | **80** | **~50-57% LUT** |

### 3.3 Linux Components

```
Host System
+-- User Application
│   +-- libfft (C/Python bindings)
│       +-- fft_init()
│       +-- fft_compute_forward()
│       +-- fft_compute_inverse()
│       +-- fft_get_config()
│
+-- Kernel Driver (fft_driver.ko)
│   +-- UIO device registration (/dev/fft_0)
│   +-- Memory-mapped register access
│   +-- Interrupt handling
│   +-- DMA setup (if supported)
│
+-- Bitstream Management
    +-- iceprog (SPI programming via Raspberry Pi GPIO)
    +-- QSPI Flash bootloader (optional)
```

---

## 4. Development Phases

### Phase 1: Environment Setup (Weeks 1-2)

**Tasks:**
- Install Project IceStorm toolchain (Yosys, nextpnr, icepack)
- Prepare ICEZero board (mount on Raspberry Pi HAT connector)
- Create base Makefile for building
- Test loading simple Verilog program (LED blink)

**Deliverables:**
- Build scripts
- Environment setup documentation
- Test bitstream for board verification

**Completion Criteria:**
- LED on ICEZero blinks at 1 Hz

---

### Phase 2: FFT Core Development (Weeks 3-6)

**Tasks:**
- Select and adapt FFT generator (dblclockfft or Sliding DFT)
- Parameterize for ICE40HX4K (32/64-point FFT)
- Write testbench (Verilog/Python)
- Formal verification of butterfly module
- RTL simulation against NumPy FFT

**Deliverables:**
- `fft_core.v` (generated Verilog)
- `fft_tb.v` (testbench)
- `verify_fft.py` (Python verification script)
- `fft_spec.md` (specification)

**Completion Criteria:**
- All tests pass
- Error < 1 LSB vs NumPy on 100 random vectors

---

### Phase 3: Peripheral Integration (Weeks 7-10)

**Tasks:**
- Develop AXI Lite slave interface
- Implement FIFO (input/output)
- UART controller for debugging
- Unit testing of each component

**Deliverables:**
- `axi_lite_slave.v`
- `fifo_512.v`
- `uart_115200.v`
- `top_design.v` (integration of all modules)

**Completion Criteria:**
- Top-level synthesis without errors
- Place & Route successful
- Resource utilization < 80% LUT

---

### Phase 4: Linux Driver Development (Weeks 11-13)

**Tasks:**
- Write UIO-based driver kernel module
- Device node creation (`/dev/fft_0`)
- Interrupt handling (optional)
- Implement ioctl for control

**Deliverables:**
- `fft_driver.c` (kernel module)
- `fft_driver.h` (API)
- Makefile for module compilation
- `README_driver.md` (documentation)

**Completion Criteria:**
- `insmod fft_driver.ko` executes without errors
- `dmesg | grep fft` shows driver loading
- `/dev/fft_0` accessible for read/write

---

### Phase 5: User-Space Library (Weeks 14-16)

**Tasks:**
- Implement C library `libfft.so` with FFTW-compatible API
- Python bindings (ctypes/CFFI)
- Examples (C and Python)
- Unit tests

**Deliverables:**
- `libfft.c` + `libfft.h`
- `libfft_py.py` (Python wrapper)
- `examples/` (3-5 examples)
- `tests/` (unit tests)

**Completion Criteria:**
- C API functions without memory leaks (valgrind check)
- Python examples run successfully
- All tests pass

---

### Phase 6: Integration Testing (Weeks 17-18)

**Tasks:**
- End-to-end testing (input -> FPGA -> output)
- Comparison with CPU FFT (NumPy)
- Performance profiling
- Stress tests

**Deliverables:**
- `tests/integration_test.py`
- `benchmarks/performance_report.md`
- Set of test signals

**Completion Criteria:**
- Accuracy matches NumPy (< 2 LSB)
- FPGA FFT faster than CPU on target sizes

---

### Phase 7: Documentation (Weeks 19-20)

**Tasks:**
- API documentation (Doxygen)
- User guide (Markdown)
- Code snippet examples
- Troubleshooting guide

**Deliverables:**
- `docs/API.md`
- `docs/USER_GUIDE.md`
- `docs/ARCHITECTURE.md`
- `LICENSE` (BSD/MIT)

---

## 5. Technical Specifications

### 5.1 FFT Engine

#### Parameters

```verilog
parameter FFT_SIZE = 64;           // 32, 64, 128
parameter INPUT_WIDTH = 16;        // bits
parameter OUTPUT_WIDTH = 20;       // bits
parameter TWIDDLE_WIDTH = 16;      // bits
parameter LATENCY = 80;            // cycles for 64-pt FFT
```

#### Interfaces

**Inputs:**
```
i_clk          : System clock (50 MHz)
i_rst          : Async reset (active high)
i_valid        : Input valid strobe
i_real[15:0]   : Real part of input
i_imag[15:0]   : Imaginary part of input
i_ce           : Clock enable
```

**Outputs:**
```
o_valid        : Output valid strobe
o_real[19:0]   : Real part of output
o_imag[19:0]   : Imaginary part
o_index[6:0]   : Bin index (0 to FFT_SIZE-1)
```

#### Performance

| FFT Size | Throughput | Latency | DSP Blocks |
|----------|-----------|---------|-----------|
| 32 | 1 sps | 40 cycles | 0 (soft mult) |
| 64 | 1 sps | 80 cycles | 0 |
| 128 | 1 sample/2 clk | 160 cycles | 0 |

#### Timing Diagram (64-point FFT)

```
         ┌──┐  ┌──┐  ┌──┐  ┌──┐  ┌──┐  ┌──┐  ┌──┐  ┌──┐
clk    ──┘  └──┘  └──┘  └──┘  └──┘  └──┘  └──┘  └──┘  └──

i_valid ──────┐                                   ┌──────
              └───────────────────────────────────┘
              |________ 64 samples _______________|
              0  1  2                        62  63

i_real  ──X────X────X── ... ──X────X──────────────────
              D0   D1              D62  D63

i_imag  ──X────X────X── ... ──X────X──────────────────
              D0   D1              D62  D63

                                  |<-- latency=80 clk -->|

o_valid ──────────────────────────────────────┐     ┌──
                                               └─────┘
                                               | 64  |
o_real  ───────────────────────────────────X────X────X──
                                            B0   B1
o_index ───────────────────────────────────X────X────X──
                                            0    1
```

**Notes**:
- Input data loaded sequentially (one sample per clock when `i_valid=1`)
- After 64th sample, computational delay of 80 cycles
- Output data produced sequentially with `o_valid=1` and bin index `o_index`
- Input FIFO blocks reception with `i_valid=1` during computation (backpressure)

#### FSM State Diagram

```
          ┌─────────┐
          │  IDLE   │<────────────────────────────┐
          └────┬────┘                             │
               │ i_valid=1 && enable=1             │
               v                                  │
          ┌─────────┐                             │
          │  LOAD   │ (receive 64 samples)         │
          └────┬────┘                             │
               │ cnt == FFT_SIZE                  │
               v                                  │
          ┌─────────┐                             │
          │  EXEC   │ (computation, 80 cycles)     │
          └────┬────┘                             │
               │ done                              │
               v                                  │
          ┌─────────┐      ┌──────────┐           │
          │ OUTPUT  │----->│  ERROR   │ (if       │
          └────┬────┘      └──────────┘ overflow)  │
               │ last_sample                        │
               └───────────────────────────────────┘
```

### 5.2 AXI Lite Register Map

| Address | Name | Bits | Type | Description |
|-------|-----|-----|-----|----------|
| 0x00 | CONTROL | [31:0] | R/W | Bit 0: enable, Bit 1: reset, Bit 2: interrupt_en |
| 0x04 | STATUS | [31:0] | R | Bit 0: ready, Bit 1: busy, Bit 2: error |
| 0x08 | CONFIG | [31:0] | R/W | Bit [4:0]: FFT_SIZE (log2), Bit [9:5]: window_type |
| 0x0C | DATA_IN | [31:0] | W | Input FIFO (real in [15:0], imag in [31:16]) |
| 0x10 | DATA_OUT | [31:0] | R | Output FIFO (real in [19:0], imag in [39:20]) |
| 0x14 | FIFO_STAT | [31:0] | R | Bit [7:0]: input level, Bit [15:8]: output level |
| 0x18 | VERSION | [31:0] | R | 0x01000000 (v1.0.0) |
| 0x1C | IRQ_STATUS | [31:0] | R/W1C | Bit 0: computation_done, Bit 1: fifo_overflow, Bit 2: fifo_underflow, Bit 3: config_error |
| 0x20 | IRQ_MASK | [31:0] | R/W | Interrupt mask (1 = enabled): bits match IRQ_STATUS |
| 0x24 | ERROR_CODE | [31:0] | R | Last error code (0 = no error) |

#### Interrupt Map

| IRQ | Bit | Source | Priority | Handler |
|-----|------|----------|-----------|------------|
| 0 | `computation_done` | FFT computation complete | Low | Read output FIFO |
| 1 | `fifo_overflow` | Input FIFO overflow | High | Reset FIFO, retransmit |
| 2 | `fifo_underflow` | Empty output FIFO read attempt | Medium | Wait for data |
| 3 | `config_error` | Invalid config (size/window) | Critical | Reset config to defaults |

#### Error Codes

| Code | Name | Description | Action |
|------|------|----------|----------|
| 0x00 | `ERR_NONE` | No error | - |
| 0x01 | `ERR_FIFO_OVF` | Input FIFO overflow | Reset input FIFO |
| 0x02 | `ERR_FIFO_UDF` | Output FIFO underflow | Wait for computation |
| 0x03 | `ERR_CFG_SIZE` | Unsupported FFT size | Reset to FFT_SIZE=64 |
| 0x04 | `ERR_CFG_WIN` | Unsupported window type | Reset to Hann |
| 0x05 | `ERR_TIMEOUT` | Hardware timeout (> 10,000 cycles) | Reset FFT core |

### 5.3 Linux Driver

**Module name**: `fft_driver`  
**Device**: `/dev/fft_0`  
**Class**: `fft`

**ioctl Codes**:
```c
#define FFT_IOCTL_MAGIC 'F'
#define FFT_GET_CONFIG    _IOR(FFT_IOCTL_MAGIC, 1, struct fft_config)
#define FFT_SET_CONFIG    _IOW(FFT_IOCTL_MAGIC, 2, struct fft_config)
#define FFT_RESET         _IO(FFT_IOCTL_MAGIC, 3)
#define FFT_GET_STATUS    _IOR(FFT_IOCTL_MAGIC, 4, struct fft_status)
```

---

## 6. Hardware and Software Requirements

### 6.1 Hardware

- **ICEZero (ICE40HX4K)**: 1 pc.
- **Raspberry Pi 4/5**: 1 pc. (host controller)
- **Micro-USB cable** (for Pi power)
- **Linux PC** (for development, connects to Pi via SSH)

### 6.2 Software

#### Required
- Project IceStorm (Yosys, nextpnr, icepack, iceprog)
- GCC toolchain
- Python 3.8+
- GNU Make

#### Optional
- Verilator (simulation)
- GTKWave (VCD viewer)
- Doxygen (documentation)
- GDB (debugging)

#### Versions

```bash
# Version check
yosys --version          # >= 0.30
nextpnr-ice40 --version # >= 0.40
python3 --version       # >= 3.8
gcc --version           # >= 9.0
```

---

## 7. Repository Structure

```
ice40-fft/
├── README.md                    # Main documentation
├── LICENSE                      # MIT/BSD license
├── Makefile                     # Top-level makefile
├── config.mk                    # Build config (paths, ARM toolchain)
│
├── .config/
│   ├── pi_address.txt          # Raspberry Pi IP/hostname (for SSH deploy)
│   ├── pi_user.txt             # SSH username (default: pi)
│   └── toolchain.cfg           # ARM cross-compiler paths
│
├── docs/
│   ├── SETUP.md                # Installation guide (PC + Pi)
│   ├── ARCHITECTURE.md         # System architecture
│   ├── DEVELOPMENT.md          # Development workflow
│   ├── DEPLOYMENT.md           # SSH deployment guide
│   ├── REMOTE_TESTING.md       # Remote testing via SSH
│   ├── API.md                  # API reference
│   ├── HARDWARE_GUIDE.md       # Hardware connections
│   └── TROUBLESHOOTING.md      # FAQ
│
├── hardware/
│   ├── rtl/
│   │   ├── fft_core.v
│   │   ├── axi_lite_slave.v
│   │   ├── fifo_256.v
│   │   ├── uart_115200.v
│   │   ├── gpio_ctrl.v
│   │   ├── sram_ctrl.v
│   │   ├── top_design.v
│   │   └── butterfly.v
│   │
│   ├── sim/
│   │   ├── fft_tb.v
│   │   ├── verify_fft.py
│   │   └── Makefile
│   │
│   ├── synth/
│   │   ├── Makefile            # Yosys/nextpnr targets
│   │   ├── icezero.pcf         # Pin constraints
│   │   ├── timing.sdc
│   │   └── build_scripts/
│   │       ├── synth.sh        # Synthesis (Yosys)
│   │       ├── pnr.sh          # Place & route (nextpnr)
│   │       └── pack.sh         # Bitstream (icepack)
│   │
│   └── scripts/
│       ├── gen_fft.py
│       ├── gen_twiddle.py
│       └── fuse_bitstream.py
│
├── software/
│   ├── kernel_driver/
│   │   ├── fft_driver.c
│   │   ├── fft_driver.h
│   │   ├── Makefile
│   │   ├── module.lds
│   │   └── cross_compile.sh
│   │
│   ├── lib/
│   │   ├── libfft.c
│   │   ├── libfft.h
│   │   ├── Makefile
│   │   ├── fftw_compat.h
│   │   └── arm_build.sh
│   │
│   ├── python/
│   │   ├── pyfft/
│   │   │   ├── __init__.py
│   │   │   ├── fft.py
│   │   │   └── examples.py
│   │   ├── setup.py
│   │   └── build_for_pi.sh
│   │
│   └── utils/
│       ├── fft_load.c          # Bitstream loader
│       ├── fft_test.c          # Test utility
│       ├── fft_profile.py      # Performance profiler
│       └── deploy.sh           # SSH deploy script
│
├── examples/
│   ├── c/
│   │   ├── simple_fft.c
│   │   ├── real_time_spectrum.c
│   │   ├── Makefile
│   │   └── Makefile.arm
│   │
│   └── python/
│       ├── simple_fft.py
│       ├── plot_spectrum.py
│       ├── benchmark.py
│       ├── test_on_pi.sh
│       └── requirements.txt
│
├── tests/
│   ├── unit/
│   │   ├── test_fft_core.py
│   │   ├── test_fifo.py
│   │   ├── test_uart.py
│   │   └── Makefile
│   │
│   ├── integration/
│   │   ├── test_end_to_end.py
│   │   ├── test_driver.py
│   │   ├── test_on_pi.py
│   │   └── run_remote_tests.sh
│   │
│   └── data/
│       ├── test_vectors.txt
│       └── expected_output.txt
│
├── scripts/
│   ├── setup_dev.sh            # Setup dev environment
│   ├── setup_pi.sh             # Setup Raspberry Pi
│   ├── build_all.sh            # Build all (PC + ARM cross-compile)
│   ├── deploy_to_pi.sh         # Deploy to Pi via SSH
│   ├── test_on_pi.sh           # Run tests via SSH
│   ├── sync_with_pi.sh         # Sync code via SSH
│   └── remote_shell.sh         # SSH shell to Pi
│
├── ci/
│   ├── .github/workflows/
│   │   ├── build.yml           # Build on push
│   │   ├── test.yml            # Run unit tests
│   │   └── cross_compile.yml   # Cross-compile for ARM
│   │
│   └── Makefile                # CI targets
│
└── .gitignore
```

---

## 8. Project Acceptance Criteria

### Criterion 1: Functionality

- [ ] FFT on FPGA works on all supported sizes (32, 64, 128)
- [ ] Results match NumPy FFT with accuracy <= 2 LSB
- [ ] Tested on random inputs (100+ tests)

### Criterion 2: Performance

- [ ] FFT latency <= 100 us (64-point)
- [ ] Peak power consumption <= 500 mW
- [ ] FPGA FFT faster than CPU version on small sizes

### Criterion 3: Reliability

- [ ] 10+ hours stress test without errors
- [ ] Edge-case handling (overflow, underflow, SRAM access)
- [ ] Formal verification of butterfly module
- [ ] Testing at various temperatures (with Raspberry Pi thermal stress)

### Criterion 4: Linux Integration

- [ ] Kernel driver loads without errors on Pi: `sudo insmod fft_driver.ko`
- [ ] `/dev/fft_0` available and functional on Pi
- [ ] User-space API works in C and Python
- [ ] No memory leaks (valgrind clean on Pi)
- [ ] Remote test execution via SSH works

### Criterion 5: SSH Deployment and Remote Testing

- [ ] `deploy_to_pi.sh` successfully uploads all artifacts to Pi
- [ ] `test_on_pi.sh` successfully runs tests via SSH
- [ ] Bitstream loaded via `iceprog` on Pi
- [ ] All integration tests pass on real hardware (Pi + ICEZero)
- [ ] No dependencies on specific paths on dev machine

### Criterion 6: Documentation

- [ ] All API functions documented (Doxygen)
- [ ] `DEVELOPMENT.md` describes Linux development workflow
- [ ] `DEPLOYMENT.md` describes deploy and testing via SSH
- [ ] User guide contains >= 3 working examples
- [ ] Troubleshooting guide for SSH issues
- [ ] Documentation in English

### Criterion 7: Codebase

- [ ] All sources in git repository
- [ ] Makefile works on clean system
- [ ] No hardcoded paths
- [ ] Coding style compliance (MISRA-C for kernel code)

---

## 9. Risks and Mitigations

| Risk | Probability | Impact | Mitigation |
|------|-----------|-----------|-----------|
| Insufficient LUT resources in HX4K | Medium | High | Use Sliding DFT instead of pipelined, synthesis optimization |
| Timing violations at 50 MHz | Low | Medium | Conservative P&R strategy, timing constraint analysis |
| Kernel driver complexity | Medium | Medium | Use UIO framework, avoid complex interrupt handling |
| Toolchain version incompatibility | Low | Medium | Pin versions in documentation |
| No built-in DSP in HX4K | High | Medium | Soft multiplication, optimized synthesis |
| Power issues from Pi | Low | Medium | Consumption monitoring, external power if needed |
| Flash memory degradation | Low | Low | Write cycle limiting, wear leveling |

---

## 10. Raspberry Pi Integration

### 10.1 HAT Interface

ICEZero connects to Raspberry Pi via standard 2x20 GPIO connector. Key pins:

- **3V3**: Power (not used, powered from 5V)
- **5V**: Main power supply (for FPGA, SRAM, all components)
- **SPI0** (GPIO8/9/10/11): Bitstream programming and data exchange (custom protocol, 8 MHz)
- **GPIO17**, **GPIO27**: For control and status (optional)
- **I2C** (GPIO2/3): For future expansion

### 10.2 Existing Examples

Based on [cliffordwolf/icotools examples/icezero](https://github.com/cliffordwolf/icotools/tree/master/examples/icezero):

- **SUMP2 Logic Analyzer**: FPGA implementation, signal analysis from Pi
- **GPIO examples**: LED control, PWM, servo control
- **SPI communication**: Between Pi and FPGA (SPI via custom protocol)

### 10.3 Bitstream Programming

FPGA configured via Raspberry Pi SPI interface:

```bash
# On Raspberry Pi (primary method):
iceprog design.bin
```

Process:
1. Bitstream synthesized on dev machine
2. `scp` uploads `.bin` to Pi
3. `iceprog` on Pi programs FPGA via SPI0 (GPIO8-11)
4. FPGA immediately runs loaded configuration

Alternatively, bitstream can be written to QSPI Flash on ICEZero board for auto-load on power-up.

### 10.4 Coexistence with Other HATs (HiFiBerry DAC+ ADC)

ICEZero uses non-overlapping GPIO pin set with HiFiBerry DAC+ ADC, enabling simultaneous operation without conflicts.

#### GPIO Usage Map

| GPIO | HiFiBerry DAC+ ADC | ICEZero | Conflict |
|------|-------------------|---------|----------|
| 2, 3 | I2C (EEPROM auto-config) | I2C (ID EEPROM + FPGA control) | OK - shared I2C bus |
| 8, 9, 10, 11 | - | **SPI0** (data + programming) | OK |
| 7 | - | SPI0 CE1 (aux channel) | OK |
| 5, 6, 12, 13, 16, 26 | - | **CFG** (FPGA config) | OK |
| 14, 15 | - | **UART** (debug) | OK |
| 18 | **I2S BCLK** | - | OK |
| 19 | **I2S FS (LRCK)** | - (NetP11_35, not connected) | OK |
| 20 | **I2S DIN** | - (NetP11_38, not connected) | OK |
| 21 | **I2S DOUT** | - (NetP11_40, not connected) | OK |
| 22, 24, 25 | - | **GPIO** (FPGA control/status) | OK |
| 4, 17, 23, 27 | - | - (not connected) | OK |

> **Conclusion**: no conflicts. I2C is a multi-device bus.
> HiFiBerry EEPROM: address 0x50. ICEZero FPGA: free address (0x30-0x3F).

#### Coexistence Recommendations

1. **Device Tree**: both HAT descriptions loaded via EEPROM or manually in `/boot/config.txt`:
   ```
   dtoverlay=hifiberry-dacplusadc
   dtoverlay=icezero-fft
   ```
2. **I2C**: ICEZero driver uses unique address, not conflicting with HiFiBerry (0x50)
3. **SPI0**: used only by ICEZero; HiFiBerry doesn't use SPI
4. **Power**: total consumption ICEZero (<=150 mA) + HiFiBerry (<60 mA) <= 210 mA — within Pi capabilities (500 mA on 5V)

---

### 10.5 Maximum Data Exchange Performance

#### Throughput Analysis

| Interface | Frequency | Theoretical Throughput | Usage |
|-----------|--------|--------------------------------------|---------------|
| **SPI0** (main channel) | 8 MHz | **1 MB/s** (8 Mbps) | FFT data + control registers |
| SPI0 CE1 (aux channel) | 8 MHz | 1 MB/s | Optional: dedicated data channel |
| I2C | 400 kHz | 50 KB/s | Low-speed telemetry/status |
| UART | 115200 baud | 14 KB/s | Debug console |

For 64-point FFT with 16-bit samples (complex):
- Input block: 64 x 4 bytes = **256 bytes**
- Output block: 64 x 4 bytes = **256 bytes**
- Total per transform: **512 bytes**

At SPI throughput of 1 MB/s: up to **2000 FFT transforms/s**.

#### Optimization Strategies

| Technique | Gain | Description |
|---------|---------|----------|
| **DMA via spidev** | +40-60% | Direct memory access without CPU |
| **Packet protocol** | +20-30% | One header per data block vs byte-by-byte |
| **Double buffering** | +30-50% | Ping-pong buffers: write/read parallel with computation |
| **SPI CE1 as second channel** | x2 | Separate command and data channels |
| **Hardware protocol decoder in FPGA** | +15-20% | Packet decoding on FPGA side without soft-CPU |

#### Expected Performance (64-pt FFT)

| Mode | Throughput | FFT/s | Latency |
|-------|----------------------|-------|------------|
| Basic (PIO, 8 MHz) | ~0.5 MB/s | ~1000 | ~1 ms |
| DMA + Packet | ~0.9 MB/s | ~1800 | ~550 us |
| DMA + Dual Buffer + 2xSPI | ~1.8 MB/s | ~3600 | ~280 us |

---

## 11. Work Plan and Resources

### 11.1 Schedule

| Phase | Weeks | Status |
|------|--------|--------|
| 1. Environment Setup | 1-2 | Pending |
| 2. FFT Core | 3-6 | Pending |
| 3. Peripherals | 7-10 | Pending |
| 4. Linux Driver | 11-13 | Pending |
| 5. User-space Library | 14-16 | Pending |
| 6. Integration & Tests | 17-18 | Pending |
| 7. Documentation | 19-20 | Pending |
| **Total** | **20 weeks** | |

### 11.2 Human Resources

| Role | Load | Competencies |
|------|----------|------------|
| FPGA/RTL Engineer | 1.0 FTE | Verilog, Yosys/nextpnr, digital circuit design |
| Linux Kernel/Driver Engineer | 0.5 FTE | C, Linux kernel API, UIO framework, ARM cross-compilation |
| Test & Documentation Engineer | 0.5 FTE | Python, pytest, Sphinx/Doxygen, technical English |

### 11.3 Hardware Budget

| Item | Quantity | Price, USD | Total, USD |
|---------|-----------|----------|-------|
| ICEZero (TE0876-03-A) | 1 | 25 | 25 |
| Raspberry Pi 4/5 | 1 | 55 | 55 |
| Micro-USB cable | 1 | 2 | 2 |
| Wires, jumpers, breadboard | - | - | 10 |
| **Total** | | | **92 USD** |

---

## 12. Approvals

| Role | Name | Signature | Date |
|------|------|---------|------|
| Specification Author | | _________ | _________ |
| FPGA Engineer | | _________ | _________ |
| Linux Engineer | | _________ | _________ |
| Lead Engineer | | _________ | _________ |
| Approver | | _________ | _________ |

---

## 13. Typical Development Workflow

### Getting Started

```bash
# 1. Clone repository
git clone https://github.com/ipmgroup/fftd.git
cd fftd

# 2. Setup development environment
./scripts/setup_dev.sh

# 3. Configure Raspberry Pi address
echo "rpia5" > .config/pi_address.txt
echo "pi" > .config/pi_user.txt
```

### Development Cycle

```bash
# 1. Compile HDL, run simulation
make -C hardware/sim

# 2. Synthesize FPGA design
make -C hardware/synth synth_ice40

# 3. Build kernel driver (cross-compile for ARM)
make -C software/kernel_driver ARM_CROSS=arm-linux-gnueabihf-

# 4. Build user-space library (ARM)
make -C software/lib ARM_CROSS=arm-linux-gnueabihf-

# 5. Build examples (ARM)
make -C examples/c ARM_CROSS=arm-linux-gnueabihf-

# 6. Deploy to Raspberry Pi
./scripts/deploy_to_pi.sh

# 7. Run integration tests on Pi via SSH
./scripts/test_on_pi.sh
```

### One-liner for Full Build and Test

```bash
make clean all && ./scripts/deploy_to_pi.sh && ./scripts/test_on_pi.sh
```

### Quick Development Loop (software changes only)

```bash
make -C software/lib ARM_CROSS=arm-linux-gnueabihf- clean all && \
  ./scripts/deploy_to_pi.sh && ./scripts/test_on_pi.sh
```

---

## 14. Script Examples

### 14.1 deploy_to_pi.sh — SSH Deployment

```bash
#!/bin/bash
set -e

PI_ADDR=$(cat .config/pi_address.txt)
PI_USER=$(cat .config/pi_user.txt)
PI_HOST="${PI_USER}@${PI_ADDR}"
REMOTE_DIR="/tmp/ice40-fft"

echo "Deploying to ${PI_HOST}..."

ssh ${PI_HOST} "mkdir -p ${REMOTE_DIR}"

echo "Uploading bitstream..."
scp build/design.bin ${PI_HOST}:${REMOTE_DIR}/

echo "Uploading kernel driver..."
scp software/kernel_driver/*.ko ${PI_HOST}:${REMOTE_DIR}/ 2>/dev/null || true

echo "Uploading libraries..."
scp software/lib/libfft.so* ${PI_HOST}:${REMOTE_DIR}/ 2>/dev/null || true
scp examples/c/fft_test ${PI_HOST}:${REMOTE_DIR}/ 2>/dev/null || true

echo "Uploading Python modules..."
scp -r software/python/pyfft ${PI_HOST}:${REMOTE_DIR}/ 2>/dev/null || true

echo "Loading bitstream on Pi..."
ssh ${PI_HOST} "cd ${REMOTE_DIR} && \
  iceprog design.bin && \
  echo 'Bitstream loaded successfully'"

echo "Deployment complete!"
```

### 14.2 test_on_pi.sh — Remote Testing via SSH

```bash
#!/bin/bash
set -e

PI_ADDR=$(cat .config/pi_address.txt)
PI_USER=$(cat .config/pi_user.txt)
PI_HOST="${PI_USER}@${PI_ADDR}"
REMOTE_DIR="/tmp/ice40-fft"

echo "Running tests on ${PI_HOST}..."

echo "Loading kernel driver..."
ssh ${PI_HOST} "cd ${REMOTE_DIR} && \
  sudo insmod fft_driver.ko && \
  echo 'Driver loaded'"

sleep 1

if [ -f ${REMOTE_DIR}/fft_test ]; then
  echo "Running C tests..."
  ssh ${PI_HOST} "cd ${REMOTE_DIR} && ./fft_test"
fi

echo "Running Python tests..."
ssh ${PI_HOST} "cd ${REMOTE_DIR} && \
  export PYTHONPATH=. && \
  python3 -m pytest tests/ -v"

echo "Unloading kernel driver..."
ssh ${PI_HOST} "sudo rmmod fft_driver"

echo "All tests passed!"
```

---

## 15. Metrological Support

### 15.1 Measurement Instruments

| Measured Parameter | Instrument | Accuracy |
|---------------------|-------------------|-------------|
| FFT accuracy (error) | Comparison with NumPy FFT (double precision) | <= 1 LSB (reference) |
| FFT latency | Oscilloscope or logic analyzer (>= 100 MHz) | +/-10 ns |
| FPGA clock frequency | Frequency counter / oscilloscope | +/-1 ppm |
| Power consumption | Multimeter (current) x voltage, or USB power meter | +/-5 mA, +/-0.1 V |
| GPIO signal levels | Oscilloscope / logic analyzer | +/-0.1 V |

### 15.2 FFT Accuracy Verification Method

1. Generate set of N >= 100 random test vectors on host (Python/NumPy)
2. Compute reference FFT (numpy.fft.fft, double precision) for each vector
3. Send vectors to FPGA, read results
4. Compute maximum absolute error: max |FPGA_k - NumPy_k|
5. Criterion: error <= 2 LSB of output width for 99.9% of samples

---

## 16. Inspection and Acceptance Procedure

### 16.1 Test Types

| Test Type | Phase | Performer |
|---------------|------|-------------|
| Preliminary (laboratory) | Phases 2-5 | FPGA Engineer |
| Acceptance | Phase 6 | Commission |
| Periodic | After delivery | QA Engineer (optional) |

### 16.2 Preliminary Test Program

1. **RTL simulation check**: all testbenches pass without errors (iverilog/Verilator)
2. **Synthesis check**: Yosys + nextpnr complete without critical warnings, LUT utilization < 80%
3. **Module check**: Unit tests for FIFO, UART, GPIO, AXI Lite slave
4. **FFT core check**: error < 1 LSB vs NumPy on 100 random vectors
5. **Driver check**: `insmod`/`rmmod` without errors, `/dev/fft_0` accessible, valgrind clean

### 16.3 Acceptance Test Program

1. **Functional testing**: End-to-end FFT at 32, 64, 128 points
2. **Accuracy testing**: error <= 2 LSB on all supported sizes
3. **Performance testing**: latency <= 100 us (64-point), clock frequency >= 50 MHz
4. **Load testing**: 10 hours continuous operation without errors
5. **Documentation check**: complete set per section 17

---

## 17. Documentation Requirements

### 17.1 Documentation Set

| Document | Format | Standard |
|----------|--------|------------------|
| Technical Specification (this document) | Markdown / PDF | GOST 34.602-2020 |
| Design Description | Markdown / PDF | GOST 19.404-79 |
| RTL Module Specification | Markdown | Internal standard |
| API Documentation (Doxygen) | HTML / PDF | Doxygen style |
| User Manual | Markdown / PDF | GOST 19.505-79 |
| Deployment Guide | Markdown | Internal standard |
| Test Program and Methodology | Markdown / PDF | GOST 19.301-79 |
| Source Code (RTL, C, Python) | Text files | In git repository |

---

## 18. Commissioning Work Plan

| # | Task | Performer | Duration |
|----|--------|-------------|-------------|
| 1 | Install Raspberry Pi OS and update | Linux Engineer | 2 hours |
| 2 | Install Project IceStorm toolchain on Pi | Linux Engineer | 1 hour |
| 3 | Physically install ICEZero on Pi HAT connector | FPGA Engineer | 15 min |
| 4 | Verify connections and power integrity | FPGA Engineer | 15 min |
| 5 | Load test bitstream (LED blink) via `iceprog` | FPGA Engineer | 15 min |
| 6 | Cross-compile and deploy `fft_driver.ko` | Linux Engineer | 1 hour |
| 7 | Load working bitstream and verify `/dev/fft_0` | FPGA + Linux Engineer | 30 min |
| 8 | Run integration tests | Test Engineer | 2 hours |
| 9 | User training (optional) | Lead Engineer | 2 hours |

---

## References

### FFT Generators and Cores

- **ZipCPU dblclockfft**: https://github.com/ZipCPU/dblclockfft
- **ICE40 FFT example**: https://github.com/mattvenn/fpga-fft
- **Sliding DFT**: https://github.com/mattvenn/fpga-sdft
- **OpenCores FFT**: https://opencores.org/projects/versatile_fft

### Linux Driver Frameworks

- **Linux FPGA Subsystem**: https://kernel.org/doc/html/latest/driver-api/fpga/
- **UIO Framework**: https://kernel.org/doc/html/latest/driver-api/uio-howto.html
- **Device drivers book**: https://lwn.net/Kernel/LDD3/

### Project IceStorm

- **Main project**: http://www.clifford.at/icestorm/
- **Nextpnr**: https://github.com/YosysHQ/nextpnr
- **Yosys**: https://github.com/YosysHQ/yosys
- **icotools (examples/icezero)**: https://github.com/cliffordwolf/icotools/tree/master/examples/icezero

### ICEZero Specific Resources

- **Trenz Electronic product**: https://www.trenz-electronic.de/de/IceZero-mit-Lattice-ICE40HX-4-Mbit-externer-SRAM-3-05-x-6-5-cm/TE0876-03-A
- **Pinout**: https://www.trenz-electronic.de/Downloads/?path=Trenz_Electronic/Pinout
- **Trenz Wiki TE0876**: https://wiki.trenz-electronic.de/display/PD/TE0876+Resources
- **Support Forum**: https://forum.trenz-electronic.de/

---

**Document Version**: 1.0  
**Last Updated**: 2026-05-31  
**Status**: Ready for Implementation
