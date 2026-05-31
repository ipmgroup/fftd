#!/usr/bin/env python3
"""
icezprog.py — FPGA Programmer for ICEZero (TE0876-03 REV02)
Adapted from blackmesalabs/ice_zero_prog (Kevin Hubbard, 2017)

Uses RPi.GPIO to bit-bang SPI to the FPGA configuration PROM.
Pin mapping for TE0876-03 REV02 (from Trenz pinout.xlsx):
  CFG_DONE = GPIO5  (P11-29)
  CFG_SI   = GPIO6  (P11-31)
  CFG_SS   = GPIO12 (P11-32)
  CFG_SO   = GPIO13 (P11-33)
  CFG_SCK  = GPIO16 (P11-36)
  CFG_RST  = GPIO26 (P11-37)

Usage:  python3 icezprog.py design.bin       — program FPGA SRAM
        python3 icezprog.py design.bin flash — program QSPI Flash
        python3 icezprog.py --reset          — reset & boot from Flash
        python3 icezprog.py --id             — read Flash ID
"""

import subprocess
import sys
import time

try:
    import RPi.GPIO as GPIO
except ImportError:
    print("⚠️  RPi.GPIO not available (not on Raspberry Pi?)")
    print("   Install: sudo apt-get install python3-rpi.gpio")
    sys.exit(1)


# ── GPIO16 conflict workaround ────────────────────────────────
# googlevoicehat-soundcard overlay claims GPIO16 (sdmode/amp-enable).
# We temporarily remove it before claiming GPIO16 for FPGA programming,
# then restore it afterwards.

_OVERLAY_NAME = "googlevoicehat-soundcard"
_overlay_was_removed = False


def _overlay_loaded(name):
    """Return True if the DT overlay with given name is currently loaded."""
    try:
        result = subprocess.run(
            ["dtoverlay", "-l"],
            capture_output=True, text=True, timeout=5
        )
        return name in result.stdout
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return False


def _release_conflicting_overlays():
    """Remove overlays that claim GPIO16. Returns True if any were removed."""
    global _overlay_was_removed
    if _overlay_loaded(_OVERLAY_NAME):
        print(f"⚠️  Releasing '{_OVERLAY_NAME}' overlay (holds GPIO16/CFG_SCK)...")
        r = subprocess.run(
            ["sudo", "dtoverlay", "-r", _OVERLAY_NAME],
            capture_output=True, text=True, timeout=10
        )
        if r.returncode == 0:
            _overlay_was_removed = True
            time.sleep(0.3)   # let the kernel settle
            return True
        else:
            print(f"   Could not remove overlay: {r.stderr.strip()}")
            print("   Try: sudo systemctl stop pipewire pulseaudio && sudo dtoverlay -r googlevoicehat-soundcard")
            return False
    return False


def _restore_overlays():
    """Re-add overlays that were removed."""
    if _overlay_was_removed:
        subprocess.run(
            ["sudo", "dtoverlay", _OVERLAY_NAME],
            capture_output=True, timeout=10
        )
        print(f"✅  Restored '{_OVERLAY_NAME}' overlay.")

# ── Pin Definitions (BCM numbering) ──────────────────────────
CFG_DONE = 5
CFG_SI   = 6
CFG_SS   = 12
CFG_SO   = 13
CFG_SCK  = 16
CFG_RST  = 26


class IceZeroProg:
    def __init__(self):
        GPIO.setwarnings(False)
        GPIO.cleanup()   # release any previously-claimed pins
        _release_conflicting_overlays()   # free GPIO16 if held by soundcard
        GPIO.setmode(GPIO.BCM)
        GPIO.setup(CFG_SS,  GPIO.OUT, initial=GPIO.HIGH)
        GPIO.setup(CFG_SCK, GPIO.OUT, initial=GPIO.LOW)
        GPIO.setup(CFG_SI,  GPIO.OUT, initial=GPIO.LOW)
        GPIO.setup(CFG_SO,  GPIO.IN)
        GPIO.setup(CFG_RST, GPIO.OUT, initial=GPIO.LOW)
        GPIO.setup(CFG_DONE, GPIO.IN)

    def cleanup(self):
        GPIO.cleanup()
        _restore_overlays()

    def spi_begin(self):
        GPIO.output(CFG_SS, GPIO.LOW)

    def spi_end(self):
        GPIO.output(CFG_SS, GPIO.HIGH)

    def spi_xfer(self, data, nbits=8):
        """Bit-bang SPI transfer with timing delays (matching original icotools)."""
        result = 0
        for i in range(nbits - 1, -1, -1):
            GPIO.output(CFG_SI, (data >> i) & 1)
            time.sleep(0.00001)  # 10us delay like original uwait_barrier_sync
            if GPIO.input(CFG_SO):
                result |= (1 << i)
            time.sleep(0.00001)
            GPIO.output(CFG_SCK, GPIO.HIGH)
            time.sleep(0.00001)
            GPIO.output(CFG_SCK, GPIO.LOW)
            time.sleep(0.00001)
        return result

    def fpga_reset(self):
        """Reset FPGA and wait for CDONE."""
        GPIO.output(CFG_RST, GPIO.LOW)
        time.sleep(0.002)
        GPIO.output(CFG_RST, GPIO.HIGH)
        time.sleep(0.5)
        if GPIO.input(CFG_DONE) != GPIO.HIGH:
            print("Warning: CDONE is low after reset")

    def prog_sram(self, bitfile):
        """Program FPGA SRAM from .bin file."""
        print(f"Programming FPGA SRAM: {bitfile}")
        # ICE40 SPI slave config protocol: SS_B must be LOW before releasing
        # CRESET_B so the FPGA enters SPI slave (SRAM) config mode instead of
        # booting from flash.
        GPIO.output(CFG_SS, GPIO.LOW)
        self.fpga_reset()
        # CDONE is LOW here — FPGA is waiting for bitstream data (expected)

        # 8 dummy clocks with SS asserted
        for _ in range(8):
            GPIO.output(CFG_SCK, GPIO.LOW)
            GPIO.output(CFG_SCK, GPIO.HIGH)

        with open(bitfile, 'rb') as f:
            data = f.read()

        for i, byte in enumerate(data):
            for bit in range(7, -1, -1):
                GPIO.output(CFG_SI, (byte >> bit) & 1)
                GPIO.output(CFG_SCK, GPIO.LOW)
                GPIO.output(CFG_SCK, GPIO.HIGH)

        # 49 dummy clocks — CDONE should go HIGH during these if config OK
        for _ in range(49):
            GPIO.output(CFG_SCK, GPIO.LOW)
            GPIO.output(CFG_SCK, GPIO.HIGH)

        GPIO.output(CFG_SS, GPIO.HIGH)
        time.sleep(0.002)
        if GPIO.input(CFG_DONE) == GPIO.HIGH:
            print(f"✅ FPGA programmed ({len(data)} bytes)")
        else:
            print("⚠️  CDONE is low — check connections")

    def _flash_spi_xfer(self, data, nbits=8):
        """Bit-bang SPI for Flash access.

        Flash uses SWAPPED SI/SO relative to FPGA config:
        - Flash SI ← Pi drives CFG_SO (BCM 13) → FPGA pin 67 → Flash SI
        - Flash SO → Pi reads CFG_SI (BCM 6) ← FPGA pin 68 ← Flash SO
        """
        result = 0
        for i in range(nbits - 1, -1, -1):
            GPIO.output(CFG_SO, (data >> i) & 1)   # MOSI to flash = CFG_SO
            time.sleep(0.00001)
            if GPIO.input(CFG_SI):                  # MISO from flash = CFG_SI
                result |= (1 << i)
            time.sleep(0.00001)
            GPIO.output(CFG_SCK, GPIO.HIGH)
            time.sleep(0.00001)
            GPIO.output(CFG_SCK, GPIO.LOW)
            time.sleep(0.00001)
        return result

    def _flash_mode_enter(self):
        """Swap SI/SO directions for flash access."""
        GPIO.setup(CFG_SI, GPIO.IN)         # Flash SO → Pi reads
        GPIO.setup(CFG_SO, GPIO.OUT)        # Flash SI ← Pi drives

    def _flash_mode_leave(self):
        """Restore SI/SO directions for FPGA config."""
        GPIO.setup(CFG_SI, GPIO.OUT)        # FPGA SI ← Pi drives
        GPIO.setup(CFG_SO, GPIO.IN)         # FPGA SO → Pi reads

    def flash_power_up(self):
        """Wake Flash from deep power-down (0xAB command)."""
        self._flash_mode_enter()
        self.spi_begin()
        self._flash_spi_xfer(0xAB)
        self.spi_end()
        time.sleep(0.01)

    def flash_read_id(self):
        """Read SPI Flash manufacturer/device ID."""
        self.flash_power_up()
        self.spi_begin()
        self._flash_spi_xfer(0x9F)
        mfg = self._flash_spi_xfer(0)
        dev = self._flash_spi_xfer(0)
        cap = self._flash_spi_xfer(0)
        self.spi_end()
        self._flash_mode_leave()
        size_mb = 1 << cap
        print(f"Flash: MFG=0x{mfg:02X} DEV=0x{dev:02X} SIZE={size_mb} MB")

    def flash_erase(self):
        """Bulk erase SPI Flash (0xC7) with fixed wait."""
        self.flash_power_up()
        self.spi_begin()
        self._flash_spi_xfer(0x06)  # Write enable
        self.spi_end()
        self.spi_begin()
        self._flash_spi_xfer(0xC7)  # Bulk erase
        self.spi_end()
        self._flash_mode_leave()
        print("Erasing Flash...")
        time.sleep(15)
        print("Erase complete")

    def flash_program(self, bitfile):
        """Program bitstream to QSPI Flash."""
        with open(bitfile, 'rb') as f:
            data = f.read()

        self._flash_mode_enter()
        self.flash_erase()
        self._flash_mode_enter()  # flash_erase calls _flash_mode_leave

        total = len(data)
        for addr in range(0, total, 256):
            chunk = data[addr:addr + 256]
            self.spi_begin()
            self._flash_spi_xfer(0x06)  # Write enable
            self.spi_end()
            self.spi_begin()
            self._flash_spi_xfer(0x02)  # Page program
            self._flash_spi_xfer((addr >> 16) & 0xFF)
            self._flash_spi_xfer((addr >> 8) & 0xFF)
            self._flash_spi_xfer(addr & 0xFF)
            for b in chunk:
                self._flash_spi_xfer(b)
            self.spi_end()
            if addr % 8192 == 0:
                print(f"  {addr} / {total} bytes...")
            time.sleep(0.01)

        self._flash_mode_leave()
        print(f"Flash programmed ({len(data)} bytes)")
        # Release pins so FPGA can boot from flash
        self.cleanup()
        time.sleep(0.5)
        # Check CDONE
        GPIO.setmode(GPIO.BCM)
        GPIO.setup(CFG_DONE, GPIO.IN)
        done = GPIO.input(CFG_DONE)
        GPIO.cleanup()
        if done:
            print("\u2705 FPGA booted from Flash")
        else:
            print("\u26a0\ufe0f  CDONE is low — try 'icezprog.py --reset'")

    def boot_flash(self):
        """Reset FPGA to boot from Flash.
        
        Releases all CFG pins to Hi-Z so the FPGA can drive the SPI bus
        as a master and load its configuration from the flash chip.
        """
        print("Booting from Flash...")
        # Ensure SS_B is HIGH before release (SPI Master mode)
        GPIO.setup(CFG_SS, GPIO.OUT, initial=GPIO.HIGH)
        GPIO.output(CFG_RST, GPIO.LOW)
        time.sleep(0.01)
        GPIO.output(CFG_RST, GPIO.HIGH)
        time.sleep(0.001)
        # Release ALL pins to Hi-Z — FPGA takes over SPI bus
        self.cleanup()
        time.sleep(0.5)
        # Quick check: re-init just to read CDONE
        GPIO.setmode(GPIO.BCM)
        GPIO.setup(CFG_DONE, GPIO.IN)
        done = GPIO.input(CFG_DONE)
        GPIO.cleanup()
        if done:
            print("✅ FPGA booted from Flash")
        else:
            print("⚠️  CDONE is low")


if __name__ == '__main__':
    prog = IceZeroProg()
    try:
        if len(sys.argv) < 2:
            print("Usage: icezprog.py <design.bin>        — program SRAM")
            print("       icezprog.py <design.bin> flash  — program Flash")
            print("       icezprog.py --reset            — boot from Flash")
            print("       icezprog.py --id               — read Flash ID")
            sys.exit(1)

        if sys.argv[1] == '--reset':
            prog.boot_flash()
        elif sys.argv[1] == '--id':
            prog.flash_read_id()
        elif len(sys.argv) > 2 and sys.argv[2] == 'flash':
            prog.flash_program(sys.argv[1])
        else:
            prog.prog_sram(sys.argv[1])
    finally:
        prog.cleanup()
