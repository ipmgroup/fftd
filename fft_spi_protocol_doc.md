# SPI_PROTOCOL.md — Raspberry Pi ↔ ICE40HX4K FFT Engine

**Version**: 1.2  
**Date**: 2026-06-04  
**Status**: Production Ready  
**Update**: Complex (re+im) 4-byte/bin output with BFP exponent; dual-clock SPI
domain (87.5 MHz) decoupled from the FFT core (43.75 MHz); reliable 16 MHz SCK

---

## 1. Overview

This document describes the SPI protocol for data exchange between Raspberry Pi and FPGA (ICE40HX4K) for Fast Fourier Transform computation.

### Key Parameters

- **SPI Frequency**: up to **16 MHz SCK** (reliable). The SPI slave runs in its
  own 87.5 MHz clock domain (`SB_PLL40_2F_PAD` GENCLK), decoupled from the
  43.75 MHz FFT core (GENCLK_HALF) via clock-domain-crossing synchronisers.
- **SPI Mode**: Mode 0 (CPOL=0, CPHA=0)
- **Byte Order**: Big-endian (MSB first)
- **Word Size**: 8 bits
- **Chip Select**: GPIO25 (active low)
- **Error Detection**: XOR Checksum — minimal FPGA resources

### Pin Assignment

```
Raspberry Pi          ICEZero (FPGA)
GPIO11 (SPI0_SCLK) → P50 (Clock)
GPIO10 (SPI0_MOSI) → P49 (Data in)
GPIO9  (SPI0_MISO) ← P48 (Data out)
GPIO25 (CS#)       → P47 (Chip select, active low)
GND                → GND
```

---

## 2. Frame Format

### 2.1 Packet Structure

```
┌────────────────────────────────────────────┐
│ Byte 0: CMD        (Command)               │
│ Byte 1: LEN        (Data length, 0-252)    │
│ Byte 2: SEQ        (Sequence number)       │
│ Byte 3: CHECKSUM   (CMD ^ LEN ^ SEQ)       │
│ Byte 4+: DATA      (N bytes, where N = LEN)│
└────────────────────────────────────────────┘
```

### 2.2 Checksum Computation

**Simple XOR of all three header bytes**:

```
CHECKSUM = CMD ⊕ LEN ⊕ SEQ

Example:
  CMD = 0x60
  LEN = 0x01
  SEQ = 0x05
  
  CHECKSUM = 0x60 ^ 0x01 ^ 0x05 = 0x64
```

**Error detection probability**: ~90%  
**FPGA LUT cost**: 4 LUT instead of 28 (CRC8)  
**Computational complexity**: minimal (3 XOR operations)

### 2.3 CMD Byte Format

```
Bit layout:
7 6 5 | 4 3 2 1 0
------|----------
Type  | Command ID

Type (3 bits):
  000 = READ   (Pi reads from FPGA)
  001 = WRITE  (Pi writes to FPGA)
  010 = EXECUTE (control command)
  011 = STATUS (status request)
  100 = ERROR  (error report)
  101-111 = Reserved
```

---

## 3. Commands

### 3.1 STATUS_REQ (0x60) — Status Request

**Request (Pi → FPGA)**:
```
MOSI: [0x60] [0x00] [SEQ] [CHECKSUM]
      CMD     LEN           (0x60 ^ 0x00 ^ SEQ)
```

**Response (FPGA → Pi)**:
```
MISO: [0x60] [0x01] [SEQ] [CHECKSUM] [STATUS]
      CMD     LEN                    (1 byte data)
```

**STATUS byte**:
```
Bit 7:   Ready    (1 = ready for operation)
Bit 6:   Busy     (1 = processing in progress)
Bit 5:   Done     (1 = FFT completed)
Bit 4:   Reserved
Bit 3-0: BFP exponent (block-floating-point shift count)
```

The low nibble carries the **BFP exponent**: the host reconstructs true FFT
values as `value << exp` (each stage that risked overflow was scaled down by ½
during compute, and `exp` counts those shifts). `exp` is stable by the time
`Done` is set.

**Example**: `0x24` = Done (bit 5) + exp=4 → multiply read bins by 2⁴ = 16

---

### 3.2 FFT_CONFIG (0x51) — FFT Configuration

**Request**:
```
MOSI: [0x51] [0x02] [SEQ] [CHECKSUM] [SIZE] [FLAGS]
      CMD     LEN           (0x51^0x02^SEQ) SIZE  FLAGS
```

**SIZE byte**:
```
0x20 = FFT-32
0x40 = FFT-64    ← recommended
0x80 = FFT-128
0x00 = FFT-256
```

**FLAGS byte**:
```
Bit 7-4: Radix type
  0x0 = Radix-2
  0x1 = Radix-4  ← recommended
  0x2 = Radix-8

Bit 3: Window enable (Hann window)
  0 = disabled
  1 = enabled

Bit 2: Scale mode
  0 = no scale
  1 = auto-scale

Bit 1-0: Reserved
```

**Response (ACK)**:
```
MISO: [0x51] [0x00] [SEQ] [CHECKSUM]
      CMD     LEN           (0x51^0x00^SEQ)
```

**Example: FFT-64 Radix-4 with window**:
```
CMD:      0x51
SIZE:     0x40 (FFT-64)
FLAGS:    0x18 (Radix-4=0x10 + Window=0x08)
CHECKSUM: 0x51 ^ 0x02 ^ 0x05 = 0x52
```

---

### 3.3 WRITE_DATA (0x41) — Send Data

**Request** (send N samples × 16-bit, big-endian):
```
MOSI: [0x41] [LEN] [SEQ] [CHECKSUM] [S0_H] [S0_L] ... [SN_H] [SN_L]
      CMD     LEN         (0x41^LEN^SEQ) (LEN bytes data)
```

**Sample format** (16-bit signed, big-endian):
```
MOSI: [Bit15:8] [Bit7:0]
      High byte  Low byte
```

**Response (ACK with byte count)**:
```
MISO: [0x41] [0x01] [SEQ] [CHECKSUM] [LEN]
      CMD     LEN           (0x41^0x01^SEQ) (echo LEN)
```

**Note**: Data is sent in chunks (max 252 bytes per frame). Address auto-increments across chunks.

---

### 3.4 READ_RESULT (0x21) — Read Result

**Request** (read N FFT bins):
```
MOSI: [0x21] [0x01] [SEQ] [CHECKSUM] [NUM_BINS]
      CMD     LEN           (0x21^0x01^SEQ) (number of bins)
```

**Response** (FFT result, **complex**, 4 bytes/bin):
```
MISO: [0x21] [N*4] [SEQ] [CHECKSUM] [Re0_H][Re0_L][Im0_H][Im0_L] ...
      CMD     LEN           (0x21^N*4^SEQ) (N*4 bytes: N bins × 4)
```

**Result format** (two 16-bit signed values, big-endian, real then imaginary):
```
Each bin = 4 bytes:  [Re15:8] [Re7:0] [Im15:8] [Im7:0]
```

Each bin is still scaled by the BFP exponent from STATUS — multiply by
`2**exp` to get true `numpy.fft` values.

**Max bins per frame**: 63 (LEN is 8-bit → 63 × 4 = 252 ≤ 255). The read
pointer auto-increments across frames; it resets to bin 0 on `frame_done`.

**Hermitian shortcut (host-side)**: for real-valued input only the unique
`N/2+1` bins need to be read; the host reconstructs the upper half via
`X[N-k] = conj(X[k])`, roughly halving readout time.

---

### 3.5 CONTROL (0x50) — FFT Control

**Request**:
```
MOSI: [0x50] [0x01] [SEQ] [CHECKSUM] [CTRL_CODE]
      CMD     LEN           (0x50^0x01^SEQ) CTRL_CODE
```

**CTRL_CODE**:
```
0x01 = START   (start FFT computation)
0x02 = STOP    (stop FFT)
0x04 = RESET   (soft reset controller)
```

**Response (ACK)**:
```
MISO: [0x50] [0x00] [SEQ] [CHECKSUM]
      CMD     LEN           (0x50^0x00^SEQ)
```

---

### 3.6 SRAM Debug Commands

### SRAM_ADDR (0x52) — Set SRAM Address Pointer

**Request** (3 bytes = 19-bit byte address):
```
MOSI: [0x52] [0x03] [SEQ] [CHECKSUM] [A18:16] [A15:8] [A7:0]
```

**Response (ACK)**:
```
MISO: [0x52] [0x00] [SEQ] [CHECKSUM]
```

### SRAM_WRITE (0x42) — Write 32-bit Word to SRAM

**Request** (4 bytes = 32-bit word, auto-increment +4):
```
MOSI: [0x42] [0x04] [SEQ] [CHECKSUM] [D31:24] [D23:16] [D15:8] [D7:0]
```

**Response (ACK)**:
```
MISO: [0x42] [0x04] [SEQ] [CHECKSUM]
```

### SRAM_READ (0x22) — Read 32-bit Word from SRAM

**Request** (no payload, auto-increment +4):
```
MOSI: [0x22] [0x00] [SEQ] [CHECKSUM]
```

**Response** (4 bytes = 32-bit word):
```
MISO: [0x22] [0x04] [SEQ] [CHECKSUM] [D31:24] [D23:16] [D15:8] [D7:0]
```

---

### 3.7 ERROR_REPORT (0x80+) — Error Report

**FPGA sends on error**:
```
MISO: [0x80] [0x01] [SEQ] [CHECKSUM] [ERROR_CODE]
      CMD     LEN           (0x80^0x01^SEQ) ERROR_CODE
```

**ERROR_CODE**:
```
0x01 = Checksum mismatch
0x02 = Invalid command
0x03 = FIFO overflow
0x04 = FIFO underflow
0x05 = Timeout
0xFF = Unknown error
```

---

## 4. Sequence Diagram

### Typical FFT cycle

```
Pi                              FPGA
│                               │
├─ STATUS_REQ ─────────────────→│
│←────────────── STATUS (Ready) ─┤
│                               │
├─ FFT_CONFIG (FFT-64) ────────→│
│←──────────────── ACK ──────────┤
│                               │
├─ WRITE_DATA (64 samples) ────→│
│←──────────── ACK (count=64) ───┤
│                               │
├─ CONTROL (START) ────────────→│
│←──────────────── ACK ──────────┤
│                               │ [FFT processing]
│                               │
├─ STATUS_REQ ─────────────────→│
│←────────────── STATUS (Busy) ──┤
│                               │
│ [wait]                        │
│                               │
├─ STATUS_REQ ─────────────────→│
│←────────────── STATUS (Done) ──┤
│                               │
├─ READ_RESULT (N bins) ───────→│
│←────── FFT_DATA (N bins) ──────┤
│                               │
```

---

## 5. Checksum Implementation

### Python

```python
def checksum(cmd, length, seq):
    return cmd ^ length ^ seq

# Examples
cs1 = checksum(0x60, 0x00, 0x01)  # STATUS_REQ: 0x61
cs2 = checksum(0x51, 0x02, 0x05)  # FFT_CONFIG: 0x52
```

### C

```c
uint8_t compute_checksum(uint8_t cmd, uint8_t len, uint8_t seq) {
    return cmd ^ len ^ seq;
}
```

---

## 6. Timing

| Parameter | Value | Description |
|-----------|-------|-------------|
| SPI Clock | up to 16 MHz | Reliable; 17 MHz+ fails (oversampling limit) |
| SPI domain | 87.5 MHz | GENCLK; oversamples SCK ~5.5× at 16 MHz |
| FFT core domain | 43.75 MHz | GENCLK_HALF; CDC to the SPI domain |
| Max chunk size | 252 bytes | Limited by LEN field (8-bit) = 63 complex bins |
| Recommended chunk | 60 bins | 60 × 4 = 240 bytes/frame |

The 4-byte/bin readout TX path emits each byte from the top of a shift
register (`tx_word`) and prefetches the next bin two byte-periods ahead, so it
keeps up with high SCK without a per-byte combinational mux.

---

## 7. FPGA State Machine

```
┌─────────┐
│  IDLE   │ ← CS=1 (deselected)
└────┬────┘
     │ CS=0 (selected)
     ▼
┌─────────────┐
│ RX_CMD      │ ← Receive command byte
└────┬────────┘
     ▼
┌─────────────┐
│ RX_LEN      │ ← Receive length byte
└────┬────────┘
     ▼
┌─────────────┐
│ RX_SEQ      │ ← Receive sequence byte
└────┬────────┘
     ▼
┌──────────────────┐
│ RX_CHECKSUM      │ ← Verify checksum
└────┬─────────────┘
     │
     ├─ OK, LEN=0 ──→ EXECUTE → TX_RESP → IDLE
     │
     ├─ OK, LEN>0 ──→ RX_DATA → EXECUTE → TX_RESP → IDLE
     │
     └─ FAIL ───────→ ERROR (0x80...) → IDLE
```

---

**Document version**: 1.2  
**Last updated**: 2026-06-04  
**Status**: Production Ready
