#!/bin/bash
# Generate bitstream for ICE40
set -e
TOP="top_design"
echo "📦 Packing bitstream..."
icepack build/$TOP.asc build/$TOP.bin
echo "✅ Bitstream ready: build/$TOP.bin ($(stat -f%z build/$TOP.bin 2>/dev/null || stat -c%s build/$TOP.bin) bytes)"
