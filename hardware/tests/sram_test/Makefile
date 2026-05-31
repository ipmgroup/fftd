# SRAM Test Makefile

include ../../../config.mk

TOP       := sram_test
BUILD_DIR := build
PCF       := sram_test.pcf
RTL       := sram_test.v sram_ctrl_simple.v ../../rtl/spi_slave_proto.v

.PHONY: synth prog clean

synth: $(BUILD_DIR)/$(TOP).bin

$(BUILD_DIR)/$(TOP).json: $(RTL)
	@mkdir -p $(BUILD_DIR)
	$(YOSYS) -p "synth_ice40 -top $(TOP) -json $@" $(RTL)

$(BUILD_DIR)/$(TOP).asc: $(BUILD_DIR)/$(TOP).json $(PCF)
	$(NEXTPNR) --hx4k --package $(FPGA_PACKAGE) \
		--json $< --pcf $(PCF) --asc $@ --freq 50

$(BUILD_DIR)/$(TOP).bin: $(BUILD_DIR)/$(TOP).asc
	$(ICEPACK) $< $@

prog: $(BUILD_DIR)/$(TOP).bin
	sudo python3 ../../../examples/blinky/icezprog.py $<

clean:
	rm -rf $(BUILD_DIR)
