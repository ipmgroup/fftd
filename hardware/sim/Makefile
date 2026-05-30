# RTL Simulation Makefile (iverilog)

RTL_DIR  := ../rtl
TB_FILES := $(wildcard *_tb.v)
VVP_OUT  := $(TB_FILES:.v=.vvp)

.PHONY: all clean

all: $(VVP_OUT)

%.vvp: %.v $(wildcard $(RTL_DIR)/*.v)
	iverilog -o $@ -I$(RTL_DIR) $< $(RTL_DIR)/*.v
	vvp $@

clean:
	rm -f *.vvp *.vcd
