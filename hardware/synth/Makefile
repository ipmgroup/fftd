# FPGA Synthesis Makefile — FFT Accelerator
# Uses Project IceStorm: Yosys → nextpnr → icepack

include ../../config.mk

TOP       := fft_top
RTL_DIR   := ../rtl
BUILD_DIR := build
PCF       := fft_top.pcf
SDC       := timing.sdc

.PHONY: synth_ice40 clean

synth_ice40: $(BUILD_DIR)/$(TOP).bin

# ── Step 1: Synthesis (Yosys) ────────────────────────
$(BUILD_DIR)/$(TOP).json: $(wildcard $(RTL_DIR)/*.v) twiddle.hex
	@mkdir -p $(BUILD_DIR)
	cp twiddle.hex $(BUILD_DIR)/
	$(YOSYS) -p "synth_ice40 -top $(TOP) -json $@" $(RTL_DIR)/fft_core.v $(RTL_DIR)/fft_top.v $(RTL_DIR)/twiddle_rom.v $(RTL_DIR)/spi_slave_proto.v $(RTL_DIR)/sram_ctrl.v

# ── Step 2: Place & Route (nextpnr) ──────────────────
$(BUILD_DIR)/$(TOP).asc: $(BUILD_DIR)/$(TOP).json $(PCF) $(SDC)
	$(NEXTPNR) --hx4k --package $(FPGA_PACKAGE) \
		--json $< --pcf $(PCF) --asc $@ --freq 50

# ── Step 3: Bitstream (icepack) ──────────────────────
$(BUILD_DIR)/$(TOP).bin: $(BUILD_DIR)/$(TOP).asc
	$(ICEPACK) $< $@

clean:
	rm -rf $(BUILD_DIR)
