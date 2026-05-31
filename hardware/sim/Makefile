# RTL Simulation Makefile (iverilog)
# Supports both *_tb.v and tb_*.v test bench patterns

RTL_DIR  := ../rtl
TB_FILES := $(wildcard *_tb.v tb_*.v)
VVP_OUT  := $(TB_FILES:.v=.vvp)

IVL_FLAGS := -g2012 -Wall

.PHONY: all clean waves

all: $(VVP_OUT)

%.vvp: %.v $(wildcard $(RTL_DIR)/*.v)
	iverilog $(IVL_FLAGS) -o $@ -I$(RTL_DIR) $< $(RTL_DIR)/*.v
	vvp $@

waves: $(VVP_OUT)
	@echo "Open .vcd with gtkwave"

clean:
	rm -f *.vvp *.vcd
