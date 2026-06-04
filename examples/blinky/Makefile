# Blinky — Test project for ICEZero (ICE40HX4K-TQ144)
# Build:  make            → synthesize + place & route → top.bin
# Prog:   make prog       → program FPGA via icezprog (run on Raspberry Pi)
# Deploy: make deploy     → scp bitstream + icezprog to Pi and program
# Clean:  make clean

TOP      := top
PCF      := icezero.pcf
BITFILE  := $(TOP).bin

# ── Detect if running on Raspberry Pi ──────────────
RASPI    := $(shell grep -q 'BCM' /proc/cpuinfo 2>/dev/null && echo 1 || echo 0)

# ── SSH target ─────────────────────────────────────
PI_ADDR  ?= $(shell cat ../../.config/pi_address.txt 2>/dev/null || echo rpia5)
PI_USER  ?= $(shell cat ../../.config/pi_user.txt 2>/dev/null || echo pi)
PI_HOST  := $(PI_USER)@$(PI_ADDR)
PI_TMP   := /tmp/icezero-blinky

# ── Toolchain ──────────────────────────────────────
YOSYS    := yosys
NEXTPNR  := nextpnr-ice40
ICEPACK  := icepack

# aarch64 cross-compiler for the Pi 5 (Pi 4/earlier: aarch64 OS still works).
CROSS64  ?= aarch64-linux-gnu-

.PHONY: all prog deploy icezprog clean

all: $(BITFILE)
	@echo "✅ Bitstream ready: $(BITFILE)"

# ── Step 1: Synthesis ──────────────────────────────
$(TOP).json: $(TOP).v $(PCF)
	$(YOSYS) -p "synth_ice40 -top $(TOP) -json $@" $<

# ── Step 2: Place & Route ──────────────────────────
$(TOP).asc: $(TOP).json $(PCF)
	nextpnr-ice40 --hx4k --package tq144 \
		--json $< --pcf $(PCF) --asc $@ --freq 50

# ── Step 3: Bitstream ──────────────────────────────
$(BITFILE): $(TOP).asc
	$(ICEPACK) $< $@

# ── Program FPGA locally (run on Raspberry Pi) ─────
prog: $(BITFILE)
	@echo "⚡ Programming FPGA SRAM..."
	sudo python3 icezprog.py $(BITFILE)

# ── Build on PC, deploy & program on Pi ────────────
deploy: $(BITFILE)
	@echo "📦 Deploying blinky to $(PI_HOST)..."
	ssh $(PI_HOST) "mkdir -p $(PI_TMP)"
	scp $(BITFILE) icezprog.py $(PI_HOST):$(PI_TMP)/
	ssh $(PI_HOST) "cd $(PI_TMP) && \
		sudo python3 icezprog.py $(BITFILE) && \
		echo '✅ Blinky programmed!'"

# ── Cross-compile the fast C programmer for the Pi (aarch64) ───────
# Build in Docker:  docker compose run --rm dev make -C examples/blinky icezprog
# Needs liblgpio-dev:arm64 (baked into the dev image). Bit-bangs the ICEZero
# CFG_* pins ~30× faster than the RPi.GPIO Python version — SRAM config in ~2.3 s.
icezprog: icezprog.c
	$(CROSS64)gcc -O2 -o $@ $< -llgpio
	@echo "✅ icezprog (aarch64) built — scp to the Pi: ./icezprog design.bin"

# ── Clean ──────────────────────────────────────────
clean:
	rm -f $(TOP).json $(TOP).asc $(TOP).bin icezprog
