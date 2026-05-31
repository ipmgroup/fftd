#!/usr/bin/env python3
"""Raw SPI diagnostic: STATUS and READ_RESULT."""
import spidev, sys

spi = spidev.SpiDev()
spi.open(0, 0)
spi.max_speed_hz = 500000
spi.mode = 0

def checksum(c, l, s):
    return c ^ l ^ s

# Read STATUS 5 times
print("=== STATUS reads ===")
for attempt in range(5):
    cmd, seq = 0x60, attempt + 1
    csum = checksum(cmd, 0, seq)
    mosi = [cmd, 0, seq, csum] + [0] * 10
    miso = spi.xfer2(mosi)
    rcmd = miso[5]
    rlen = miso[6]
    rseq = miso[7]
    rcsum = miso[8]
    data = miso[9]
    ok = rcsum == checksum(rcmd, rlen, rseq)
    status = "OK" if ok else "BAD"
    print(f"  #{attempt}: rcmd=0x{rcmd:02x} rlen={rlen} rseq={rseq} data=0x{data:02x} {status}")

# Read 4 bins
print("\n=== READ_RESULT 4 bins ===")
cmd, seq = 0x21, 6
nbins = 4
csum = checksum(cmd, 1, seq)
mosi = [cmd, 1, seq, csum, nbins] + [0] * 25
miso = spi.xfer2(mosi)
resp_start = 4 + 1 + 1
rcmd = miso[resp_start]
rlen = miso[resp_start + 1]
rseq = miso[resp_start + 2]
rcsum = miso[resp_start + 3]
ok = rcsum == checksum(rcmd, rlen, rseq)
print(f"  rcmd=0x{rcmd:02x} rlen={rlen} rseq={rseq} ok={ok}")
data = miso[resp_start + 4 : resp_start + 4 + 16]
for i in range(4):
    re_hi, re_lo, im_hi, im_lo = data[i * 4 : i * 4 + 4]
    re_val = (re_hi << 8) | re_lo
    im_val = (im_hi << 8) | im_lo
    if re_val & 0x8000:
        re_val -= 0x10000
    if im_val & 0x8000:
        im_val -= 0x10000
    print(f"  bin{i}: 0x{re_hi:02x}{re_lo:02x} 0x{im_hi:02x}{im_lo:02x} -> re={re_val:6d} im={im_val:6d}")

spi.close()
