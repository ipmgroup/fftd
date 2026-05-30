# FPGA Synthesis Makefile
# Uses Project IceStorm: Yosys → nextpnr → icepack

include ../../config.mk

TOP       := top_design
RTL_DIR   := ../rtl
BUILD_DIR := build
PCF       := icezero.pcf
SDC       := timing.sdc

.PHONY: synth_ice40 clean

synth_ice40: $(BUILD_DIR)/$(TOP).bin

# ── Step 1: Synthesis (Yosys) ────────────────────────
$(BUILD_DIR)/$(TOP).json: $(wildcard $(RTL_DIR)/*.v)
	@mkdir -p $(BUILD_DIR)
	$(YOSYS) -p "synth_ice40 -top $(TOP) -json $@" $(RTL_DIR)/*.v

# ── Step 2: Place & Route (nextpnr) ──────────────────
$(BUILD_DIR)/$(TOP).asc: $(BUILD_DIR)/$(TOP).json $(PCF) $(SDC)
	$(NEXTPNR) --$(FPGA_DEVICE) --package $(FPGA_PACKAGE) \
		--json $< --pcf $(PCF) --asc $@ --freq 50

# ── Step 3: Bitstream (icepack) ──────────────────────
$(BUILD_DIR)/$(TOP).bin: $(BUILD_DIR)/$(TOP).asc
	$(ICEPACK) $< $@

clean:
	rm -rf $(BUILD_DIR)
