# SPI_PROTOCOL.md — Raspberry Pi ↔ ICE40HX4K FFT Engine

**Version**: 1.3  
**Date**: 2026-06-04  
**Status**: Production Ready  
**Update**: Complex (re+im) 4-byte/bin output with BFP exponent; dual-clock SPI
domain (87.5 MHz) decoupled from the FFT core (43.75 MHz); BULK_READ (0x23)
streaming readout; re-measured reliable ceiling 14 MHz SCK; SRAM double-buffer
enabling compute/readout overlap (≈2× throughput)

---

## 1. Overview

This document describes the SPI protocol for data exchange between Raspberry Pi and FPGA (ICE40HX4K) for Fast Fourier Transform computation.

### Key Parameters

- **SPI Frequency**: up to **14 MHz SCK** (reliable, 0/10 fails bit-exact;
  15 MHz+ drops bits). The SPI slave runs in its own 87.5 MHz clock domain
  (`SB_PLL40_2F_PAD` GENCLK), decoupled from the 43.75 MHz FFT core
  (GENCLK_HALF) via clock-domain-crossing synchronisers.
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

### 3.4a BULK_READ (0x23) — Streaming Read (one transaction)

`READ_RESULT` is capped at 63 bins/frame by the 8-bit LEN field, so a full
spectrum needs ~9 separate SPI transactions — and the per-transaction overhead
(command echo + gap + host syscall) dominates the readout time. `BULK_READ`
removes that overhead: the FPGA streams 4-byte bins continuously **for as long
as CS stays asserted**, starting from bin 0. The master simply clocks the exact
number of bytes it wants, then deasserts CS to stop the stream.

**Request** (no data bytes):
```
MOSI: [0x23] [0x00] [SEQ] [CHECKSUM]
      CMD     LEN           (0x23^0x00^SEQ)
```

**Response** (TX header, then an unbounded bin stream):
```
MISO: [0x23] [0x04] [SEQ] [CHECKSUM] [Re0_H][Re0_L][Im0_H][Im0_L][Re1_H]...
      CMD     LEN           (echoed)   ← stream continues until CS deasserts →
```

- The TX-header LEN field (`0x04`) is a placeholder; the real byte count is
  defined by how long the master keeps CS low, **not** by LEN.
- The read pointer restarts at bin 0 on each `BULK_READ`, so repeated bulk reads
  of the same result are allowed without recomputing.
- Bins are BFP-scaled exactly like `READ_RESULT`; the Hermitian host-side
  shortcut applies (`N/2+1` bins for real input).
- **spidev note**: one transaction carries `9 + n_bins*4` bytes. The default
  spidev transfer buffer is 4096 B, so Hermitian (`N/2+1 = 513` bins → 2061 B)
  fits comfortably; a full 1024-bin read needs `spidev.bufsiz` raised.

#### SRAM double-buffer & pipelined throughput

After every frame the FPGA copies the 1024 complex bins from the FFT core BRAM
into external SRAM (transparent to the host — the readout simply streams from
SRAM). Because the result lives in SRAM, the core BRAM is free to compute the
next frame **while the host is still reading the previous one**. The hardware
defers the next BRAM→SRAM copy until the current read finishes, so a single
SRAM buffer is sufficient and no protocol field changes.

To exploit the overlap the host pipelines START with the read of the previous
frame:

```
control(START); wait_done()          # prime frame 0
loop:
    control(START)                   # kick frame n+1 (computes during the read)
    bins = bulk_read(N, hermitian)   # stream frame n from SRAM
    wait_done()                      # frame n+1 copied to SRAM (short — compute
                                     #   already finished under the readout)
```

Measured: serial ≈ 4.0 ms/frame → pipelined ≈ 2.0 ms/frame (**~2.0× throughput**,
~500 FFT/s @ 14 MHz SCK). The STATUS BFP exponent is latched per buffer, so the
value the host rescales with always matches the frame being read, even while a
different exponent is being computed for the next frame.

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
| SPI Clock | up to 14 MHz | Reliable (0/10, bit-exact); 15 MHz+ drops bits |
| SPI domain | 87.5 MHz | GENCLK; oversamples SCK ~6× at 14 MHz |
| FFT core domain | 43.75 MHz | GENCLK_HALF; CDC to the SPI domain |
| Max chunk size | 252 bytes | Limited by LEN field (8-bit) = 63 complex bins |
| Recommended chunk | 60 bins | 60 × 4 = 240 bytes/frame (chunked 0x21) |
| Readout (Hermitian @14 MHz) | chunked 2.29 ms / bulk 1.81 ms | BULK_READ 0x23 ≈ 1.27× faster |

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
