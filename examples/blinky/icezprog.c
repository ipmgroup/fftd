/*
 *  icezprog — FPGA Programming Tool for ICEZero (TE0876-03, REV02)
 *
 *  Adapted from cliffordwolf/icotools examples/icezero/icezprog.c
 *  Original by Kevin M. Hubbard (blackmesalabs/ice_zero_prog)
 *
 *  GPIO pin mapping for TE0876-03 REV02 (from Trenz pinout.xlsx):
 *    CFG_DONE  = GPIO5  (P11-29)
 *    CFG_SI    = GPIO6  (P11-31)
 *    CFG_SS    = GPIO12 (P11-32)
 *    CFG_SO    = GPIO13 (P11-33)
 *    CFG_SCK   = GPIO16 (P11-36)
 *    CFG_RST   = GPIO26 (P11-37)
 *
 *  Build:  gcc -o icezprog icezprog.c -llgpio
 *  Usage:  ./icezprog design.bin    — program FPGA SRAM
 *          ./icezprog .             — program FPGA Flash (first sector)
 *          ./icezprog ..            — reset & boot from Flash
 *
 *  Requires lgpio (sudo apt install liblgpio-dev).
 *  Auto-detects gpiochip4 (Pi5) or gpiochip0 (Pi4 and earlier).
 */

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <sys/stat.h>
#include <lgpio.h>

// ── ICEZero REV02 Pin Definitions (BCM GPIO numbers) ──
#define CFG_SS   12  // P11-32, GPIO12
#define CFG_SCK  16  // P11-36, GPIO16
#define CFG_SI    6  // P11-31, GPIO6
#define CFG_SO   13  // P11-33, GPIO13
#define CFG_RST  26  // P11-37, GPIO26
#define CFG_DONE  5  // P11-29, GPIO5

// ── lgpio handle (set in main) ──────────────────────
static int gh = -1;

// ── GPIO helpers ────────────────────────────────────
static inline void gpio_write(int pin, int val) { lgGpioWrite(gh, pin, val); }
static inline int  gpio_read(int pin)            { return lgGpioRead(gh, pin); }

// ── Flash mode: swap SI/SO directions ───────────────
// FPGA config: CFG_SI(6)=OUT, CFG_SO(13)=IN
// Flash access: CFG_SO(13)=OUT, CFG_SI(6)=IN
static void flash_mode_enter(void) {
    lgGpioFree(gh, CFG_SI);
    lgGpioFree(gh, CFG_SO);
    lgGpioClaimInput(gh, 0, CFG_SI);    // Flash SO → Pi reads
    lgGpioClaimOutput(gh, 0, CFG_SO, 0); // Flash SI ← Pi drives
}
static void flash_mode_leave(void) {
    lgGpioFree(gh, CFG_SI);
    lgGpioFree(gh, CFG_SO);
    lgGpioClaimOutput(gh, 0, CFG_SI, 0); // FPGA SI ← Pi drives
    lgGpioClaimInput(gh, 0, CFG_SO);     // FPGA SO → Pi reads
}

static uint32_t spi_xfer(uint32_t data, int nbits) {
    uint32_t rdata = 0;
    for (int i = nbits-1; i >= 0; i--) {
        gpio_write(CFG_SI, (data >> i) & 1);
        gpio_write(CFG_SCK, 1);
        if (gpio_read(CFG_SO)) rdata |= (1 << i);
        gpio_write(CFG_SCK, 0);
    }
    return rdata;
}

// ── FPGA Reset ──────────────────────────────────────
// Toggles CRESET_B. SS_B state at CRESET release determines config mode:
//   SS_B LOW  → SPI slave (SRAM programming)
//   SS_B HIGH → SPI master boot from flash
static void fpga_reset(void) {
    gpio_write(CFG_RST, 0);
    usleep(2000);
    gpio_write(CFG_RST, 1);
    usleep(2000);   // tRP: wait for FPGA internal init (1.2 ms min)
}

// ── Program SRAM ────────────────────────────────────
static void prog_sram(FILE *f) {
    printf("Programming FPGA SRAM...\n");

    // ICE40 SPI slave config: SS_B must be LOW before releasing CRESET_B
    // so the FPGA enters SPI slave config mode instead of booting from flash.
    gpio_write(CFG_SS, 0);
    fpga_reset();
    // CDONE is LOW here — FPGA is waiting for bitstream data (expected)

    // 8 dummy clocks with SS asserted
    for (int i = 0; i < 8; i++) {
        gpio_write(CFG_SCK, 0);
        gpio_write(CFG_SCK, 1);
    }

    // Send bitstream
    int byte_cnt = 0;
    for (;;) {
        int byte = getc(f);
        if (byte == EOF) break;
        for (int i = 7; i >= 0; i--) {
            gpio_write(CFG_SI, (byte >> i) & 1);
            gpio_write(CFG_SCK, 0);
            gpio_write(CFG_SCK, 1);
        }
        byte_cnt++;
    }

    // 49 dummy clocks — CDONE should go HIGH during these if config succeeded
    for (int i = 0; i < 49; i++) {
        gpio_write(CFG_SCK, 0);
        gpio_write(CFG_SCK, 1);
    }

    gpio_write(CFG_SS, 1);
    usleep(2000);
    if (gpio_read(CFG_DONE))
        printf("✅ FPGA programmed successfully (%d bytes)\n", byte_cnt);
    else
        fprintf(stderr, "⚠️  CDONE is low — programming may have failed\n");
}

// ── Flash bit-bang (SI/SO SWAPPED vs FPGA config!) ──
// For flash access: Pi → CFG_SO(13) → Flash SI, Pi ← CFG_SI(6) ← Flash SO
static uint32_t flash_spi_xfer(uint32_t data, int nbits) {
    uint32_t rdata = 0;
    for (int i = nbits-1; i >= 0; i--) {
        gpio_write(CFG_SO, (data >> i) & 1);  // MOSI to flash = CFG_SO
        gpio_write(CFG_SCK, 1);
        if (gpio_read(CFG_SI)) rdata |= (1 << i);  // MISO from flash = CFG_SI
        gpio_write(CFG_SCK, 0);
    }
    return rdata;
}

static void flash_spi_begin(void) { gpio_write(CFG_SS, 0); }
static void flash_spi_end(void)   { gpio_write(CFG_SS, 1); }
static void flash_power_up(void) {
    flash_spi_begin();
    flash_spi_xfer(0xAB, 8);  // release from deep power-down
    flash_spi_end();
    usleep(100);
}

static void flash_read_id(void) {
    flash_spi_begin();
    flash_spi_xfer(0x9F, 8);
    uint8_t mfg = flash_spi_xfer(0, 8);
    uint8_t mem = flash_spi_xfer(0, 8);
    uint8_t cap = flash_spi_xfer(0, 8);
    flash_spi_end();
    printf("Flash ID: %02X %02X %02X\n", mfg, mem, cap);
}

static void flash_write_enable(void) {
    flash_spi_begin();
    flash_spi_xfer(0x06, 8);
    flash_spi_end();
}

// Read status register (0x05); bit0 = WIP (write/erase in progress).
static uint8_t flash_read_status(void) {
    flash_spi_begin();
    flash_spi_xfer(0x05, 8);
    uint8_t s = flash_spi_xfer(0, 8);
    flash_spi_end();
    return s;
}

// Block until the flash finishes the current write/erase (WIP clears).
static void flash_wait_wip(void) {
    while (flash_read_status() & 0x01)
        usleep(1000);
}

// Whole-chip erase (0xC7). Required before programming a full bitstream:
// the previous per-sector erase only cleared the first 4 KB, so the rest of
// a ~135 KB bitstream was written into non-erased flash and corrupted.
static void flash_chip_erase(void) {
    flash_write_enable();
    flash_spi_begin();
    flash_spi_xfer(0xC7, 8);
    flash_spi_end();
    flash_wait_wip();   // chip erase takes several seconds
}

static void flash_erase_sector(uint32_t addr) {
    flash_write_enable();
    flash_spi_begin();
    flash_spi_xfer(0x20, 8);
    flash_spi_xfer(addr >> 16, 8);
    flash_spi_xfer(addr >> 8, 8);
    flash_spi_xfer(addr, 8);
    flash_spi_end();
    usleep(100000);  // 100ms for sector erase
}

static void flash_program_page(uint32_t addr, uint8_t *data, int len) {
    flash_write_enable();
    flash_spi_begin();
    flash_spi_xfer(0x02, 8);
    flash_spi_xfer(addr >> 16, 8);
    flash_spi_xfer(addr >> 8, 8);
    flash_spi_xfer(addr, 8);
    for (int i = 0; i < len; i++)
        flash_spi_xfer(data[i], 8);
    flash_spi_end();
    usleep(10000);  // 10ms for page program
}

// ── Program Flash ───────────────────────────────────
// CRESET_B is held LOW by main() before this is called,
// so the FPGA is in reset and the SPI flash bus is accessible.
static void prog_flash(FILE *f) {
    flash_mode_enter();
    flash_power_up();
    flash_read_id();

    printf("Erasing Flash (whole chip)...\n");
    fflush(stdout);
    flash_chip_erase();

    printf("Programming Flash...\n");
    uint8_t buf[256];
    int total = 0;
    for (int page = 0;; page++) {
        size_t n = fread(buf, 1, sizeof(buf), f);
        if (n == 0) break;
        flash_program_page(page * 256, buf, n);
        flash_wait_wip();
        total += n;
        if (total % 8192 == 0) { printf("  %d bytes...\n", total); fflush(stdout); }
    }
    printf("✅ Flash programmed (%d bytes)\n", total);
    flash_mode_leave();
}

// ── Release all GPIOs to Hi-Z (like Python GPIO.cleanup) ──
// For each pin: claim as INPUT with no pull, then free.
// This matches what RPi.GPIO.cleanup() does via lgpio.
static void release_all_pins(void) {
    int pins[] = {CFG_SS, CFG_SCK, CFG_SI, CFG_SO, CFG_RST, CFG_DONE};
    for (int i = 0; i < 6; i++) {
        lgGpioClaimInput(gh, 0, pins[i]);  // input, no pull (SET_PULL_NONE=0)
        lgGpioFree(gh, pins[i]);
    }
    lgGpiochipClose(gh);
    gh = -1;
}

// ── Boot from Flash ─────────────────────────────────
// Release all pins so FPGA can drive SPI bus as master.
static void boot_from_flash(void) {
    printf("Booting FPGA from Flash...\n");
    fflush(stdout);
    // Ensure SS_B HIGH at CRESET release for SPI Master mode
    gpio_write(CFG_SS, 1);
    gpio_write(CFG_RST, 0);
    usleep(10000);
    gpio_write(CFG_RST, 1);
    usleep(2000);  // 2ms for FPGA to sample mode pins
    // Release ALL pins (like Python GPIO.cleanup())
    release_all_pins();
    usleep(500000);
    // Quick check: re-open to read CDONE
    struct stat st;
    int chip = (stat("/dev/gpiochip4", &st) == 0) ? 4 : 0;
    int h = lgGpiochipOpen(chip);
    if (h >= 0) {
        lgGpioClaimInput(h, 0, CFG_DONE);
        if (lgGpioRead(h, CFG_DONE))
            printf("✅ FPGA booted from Flash\n");
        else
            fprintf(stderr, "⚠️  CDONE is low\n");
        lgGpiochipClose(h);
    }
}

// ── Main ────────────────────────────────────────────
int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "Usage: %s <bitstream.bin>   — program FPGA SRAM\n", argv[0]);
        fprintf(stderr, "       %s .                  — erase Flash & program\n", argv[0]);
        fprintf(stderr, "       %s ..                 — reset & boot from Flash\n", argv[0]);
        return 1;
    }

    // Auto-detect gpiochip: Pi5 uses chip 4, Pi4 and earlier use chip 0
    struct stat st;
    int chip = (stat("/dev/gpiochip4", &st) == 0) ? 4 : 0;
    gh = lgGpiochipOpen(chip);
    if (gh < 0) {
        fprintf(stderr, "Error: cannot open /dev/gpiochip%d: %s\n", chip, lguErrorText(gh));
        return 1;
    }

    lgGpioClaimOutput(gh, 0, CFG_SS,  1);   // SS idle HIGH
    lgGpioClaimOutput(gh, 0, CFG_SCK, 0);
    lgGpioClaimOutput(gh, 0, CFG_SI,  0);
    lgGpioClaimInput (gh, 0, CFG_SO);
    lgGpioClaimOutput(gh, 0, CFG_RST, 0);   // hold FPGA in reset
    lgGpioClaimInput (gh, 0, CFG_DONE);

    if (strcmp(argv[1], "..") == 0) {
        boot_from_flash();
    } else if (strcmp(argv[1], ".") == 0) {
        prog_flash(stdin);
        boot_from_flash();
        return 0;
    } else if (strcmp(argv[1], "..") == 0) {
        // Boot only: set SS high, pulse reset, release pins
        gpio_write(CFG_SS, 1);
        gpio_write(CFG_RST, 0);
        usleep(10000);
        gpio_write(CFG_RST, 1);
        usleep(2000);
        release_all_pins();
        usleep(500000);
        // Check CDONE
        chip = (stat("/dev/gpiochip4", &st) == 0) ? 4 : 0;
        int h = lgGpiochipOpen(chip);
        if (h >= 0) {
            lgGpioClaimInput(h, 0, CFG_DONE);
            printf(lgGpioRead(h, CFG_DONE) ? "✅ FPGA booted from Flash\n" : "⚠️  CDONE is low\n");
            lgGpiochipClose(h);
        }
        return 0;
    } else {
        FILE *f = fopen(argv[1], "rb");
        if (!f) { perror(argv[1]); lgGpiochipClose(gh); return 1; }
        prog_sram(f);
        fclose(f);
    }

    lgGpiochipClose(gh);
    return 0;
}
