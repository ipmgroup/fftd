# Timing constraints for ICE40HX4K (speed grade 5)
# Target: 50 MHz system clock (derived from 100 MHz oscillator via PLL)

# ── Clock ────────────────────────────────────────────
create_clock -name clk -period 20.0 [get_ports clk]   # 50 MHz (after PLL divide-by-2)

# ── Input/Output Delays ──────────────────────────────
set_input_delay  -clock clk -max 4.0 [get_ports {spi_mosi spi_sck spi_ce0 spi_ce1}]
set_input_delay  -clock clk -min 1.0 [get_ports {spi_mosi spi_sck spi_ce0 spi_ce1}]
set_output_delay -clock clk -max 6.0 [get_ports {spi_miso}]
set_output_delay -clock clk -min 2.0 [get_ports {spi_miso}]

# ── False Paths ──────────────────────────────────────
set_false_path -from [get_ports {btn}]
set_false_path -to   [get_ports {led[*]}]
