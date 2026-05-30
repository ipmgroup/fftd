#!/bin/bash
# Yosys synthesis script for ICE40-FFT
set -e
RTL_DIR="../rtl"
TOP="top_design"
echo "🔧 Synthesizing $TOP..."
yosys -p "synth_ice40 -top $TOP -json build/$TOP.json" $RTL_DIR/*.v
echo "✅ Synthesis complete: build/$TOP.json"
