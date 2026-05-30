#!/bin/bash
# Raspberry Pi initial setup script
# Run ON the Raspberry Pi, not on the dev machine
set -e

echo "🔧 Setting up Raspberry Pi for ICEZero FFT..."

# Install IceStorm toolchain
sudo apt-get update
sudo apt-get install -y yosys nextpnr-ice40 icepack

# Enable SPI
sudo raspi-config nonint do_spi 0

# Enable I2C
sudo raspi-config nonint do_i2c 0

echo "✅ Raspberry Pi ready for ICEZero!"
echo "   Reboot recommended: sudo reboot"
