#!/bin/bash
# Deploy build artifacts to Raspberry Pi via SSH
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_DIR"

PI_ADDR=$(cat .config/pi_address.txt 2>/dev/null || echo "rpia5")
PI_USER=$(cat .config/pi_user.txt 2>/dev/null || echo "pi")
PI_HOST="${PI_USER}@${PI_ADDR}"
REMOTE_DIR="/home/pi/fftd"

echo "📦 Deploying to ${PI_HOST}..."

# Create remote directory
ssh ${PI_HOST} "mkdir -p ${REMOTE_DIR}/hardware/scripts ${REMOTE_DIR}/hardware/synth/build"

# Upload bitstream
if [ -f hardware/synth/build/fft_top.bin ]; then
    echo "📥 Uploading bitstream..."
    scp hardware/synth/build/fft_top.bin ${PI_HOST}:${REMOTE_DIR}/hardware/synth/build/
fi

# Upload Python scripts
echo "📥 Uploading Python scripts..."
scp hardware/scripts/fft_proto.py ${PI_HOST}:${REMOTE_DIR}/hardware/scripts/
scp hardware/scripts/hw_compare.py ${PI_HOST}:${REMOTE_DIR}/hardware/scripts/
scp hardware/scripts/*.py ${PI_HOST}:${REMOTE_DIR}/hardware/scripts/ 2>/dev/null || true

# Load bitstream on Pi (ICEZero uses icezprog via SPI)
if ssh ${PI_HOST} "test -f ${REMOTE_DIR}/hardware/synth/build/fft_top.bin"; then
    echo "⚡ To load bitstream on Pi, run:"
    echo "   cd ${REMOTE_DIR} && python3 examples/blinky/icezprog.py hardware/synth/build/fft_top.bin"
fi

echo "✅ Deploy complete!"
echo ""
echo "═══ Next steps on Raspberry Pi: ═══"
echo " cd ${REMOTE_DIR}"
echo " sudo python3 examples/blinky/icezprog.py hardware/synth/build/fft_top.bin"
echo " python3 hardware/scripts/hw_compare.py"
