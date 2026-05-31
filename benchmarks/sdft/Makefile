# SDFT Synthesis Makefile — ICE40HX4K benchmark
include ../../../config.mk

TOP       := sdft_bench
RTL_DIR   := ../hdl
BUILD_DIR := build
PCF       := sdft_bench.pcf
SDC       := sdft_bench.sdc

.PHONY: synth clean

synth: $(BUILD_DIR)/$(TOP).bin

$(BUILD_DIR)/$(TOP).json: $(RTL_DIR)/sdft.v $(RTL_DIR)/complex_mult.v $(RTL_DIR)/twiddle_rom.v $(RTL_DIR)/freq_bram.v sdft_bench.v
	@mkdir -p $(BUILD_DIR)
	$(YOSYS) -p "synth_ice40 -top $(TOP) -json $@" \
		$(RTL_DIR)/sdft.v \
		$(RTL_DIR)/complex_mult.v \
		$(RTL_DIR)/twiddle_rom.v \
		$(RTL_DIR)/freq_bram.v \
		sdft_bench.v

$(BUILD_DIR)/$(TOP).asc: $(BUILD_DIR)/$(TOP).json $(PCF) $(SDC)
	$(NEXTPNR) --hx4k --package $(FPGA_PACKAGE) \
		--json $< --pcf $(PCF) --asc $@ --freq 50

$(BUILD_DIR)/$(TOP).bin: $(BUILD_DIR)/$(TOP).asc
	$(ICEPACK) $< $@

clean:
	rm -rf $(BUILD_DIR)
