#!/bin/bash
# Full build: simulation + synthesis + ARM cross-compile
set -e
echo "🏗️  Building everything..."
make -C hardware/sim
make -C hardware/synth synth_ice40
make -C software/kernel_driver
make -C software/lib
echo "✅ All builds complete!"
