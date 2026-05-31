# Multiplier Configurations Benchmark
include ../../config.mk

TOP       := mul_configs
BUILD_DIR := build_$(CONFIG)
PCF       := mul_bench.pcf
SDC       := mul_bench.sdc

.PHONY: synth clean

synth: $(BUILD_DIR)/$(TOP).bin

$(BUILD_DIR)/$(TOP).json: mul_configs.v
	@mkdir -p $(BUILD_DIR)
	$(YOSYS) -p "read_verilog -D CONFIG=$(CONFIG) mul_configs.v; synth_ice40 -top $(TOP) -json $(BUILD_DIR)/$(TOP).json"

$(BUILD_DIR)/$(TOP).asc: $(BUILD_DIR)/$(TOP).json $(PCF) $(SDC)
	$(NEXTPNR) --hx4k --package $(FPGA_PACKAGE) \
		--json $(BUILD_DIR)/$(TOP).json --pcf $(PCF) --asc $(BUILD_DIR)/$(TOP).asc --freq $(FREQ)

$(BUILD_DIR)/$(TOP).bin: $(BUILD_DIR)/$(TOP).asc
	$(ICEPACK) $(BUILD_DIR)/$(TOP).asc $(BUILD_DIR)/$(TOP).bin

clean:
	rm -rf build_*
