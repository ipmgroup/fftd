# Blinky — Test project for ICEZero (ICE40HX4K-TQ144)
# Build: make            → synthesize + place & route → top.bin
# Prog:  make prog       → program FPGA via iceprog (on Raspberry Pi)
# Clean: make clean

TOP      := top
PCF      := icezero.pcf

# ── Detect if running on Raspberry Pi (for programming) ──
RASPI    := $(shell grep -q 'BCM' /proc/cpuinfo 2>/dev/null && echo 1 || echo 0)

# ── Toolchain ──────────────────────────────────────
YOSYS    := yosys
NEXTPNR  := nextpnr-ice40
ICEPACK  := icepack
ICEPROG  := iceprog

.PHONY: all prog clean

all: $(TOP).bin
	@echo "✅ Bitstream ready: $(TOP).bin"

# ── Step 1: Synthesis ──────────────────────────────
$(TOP).json: $(TOP).v $(PCF)
	$(YOSYS) -p "synth_ice40 -top $(TOP) -json $@" $<

# ── Step 2: Place & Route ──────────────────────────
$(TOP).asc: $(TOP).json $(PCF)
	$(NEXTPNR) --hx4k --package tq144 --speed 5 \
		--json $< --pcf $(PCF) --asc $@ --freq 50

# ── Step 3: Bitstream ──────────────────────────────
$(TOP).bin: $(TOP).asc
	$(ICEPACK) $< $@

# ── Program FPGA (run on Raspberry Pi) ─────────────
prog: $(TOP).bin
ifeq ($(RASPI),1)
	$(ICEPROG) $(TOP).bin
else
	@echo "⚠️  Not on Raspberry Pi. Copy $(TOP).bin to Pi and run:"
	@echo "   iceprog $(TOP).bin"
endif

# ── Clean ──────────────────────────────────────────
clean:
	rm -f $(TOP).json $(TOP).asc $(TOP).bin
