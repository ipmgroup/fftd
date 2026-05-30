#!/bin/bash
# Place & Route for ICE40HX4K
set -e
TOP="top_design"
echo "📍 Place & Route for $TOP (ICE40HX4K-TQ144, speed 5)..."
nextpnr-ice40 --hx4k --package tq144 --speed 5 \
    --json build/$TOP.json --pcf icezero.pcf --asc build/$TOP.asc --freq 50
echo "✅ P&R complete: build/$TOP.asc"
