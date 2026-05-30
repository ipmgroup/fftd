#!/bin/bash
# Deploy build artifacts to Raspberry Pi via SSH
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_DIR"

PI_ADDR=$(cat .config/pi_address.txt 2>/dev/null || echo "rpia5")
PI_USER=$(cat .config/pi_user.txt 2>/dev/null || echo "pi")
PI_HOST="${PI_USER}@${PI_ADDR}"
REMOTE_DIR="/tmp/ice40-fft"

echo "📦 Deploying to ${PI_HOST}..."

# Create remote directory
ssh ${PI_HOST} "mkdir -p ${REMOTE_DIR}"

# Upload bitstream
if [ -f hardware/synth/build/top_design.bin ]; then
    echo "📥 Uploading bitstream..."
    scp hardware/synth/build/top_design.bin ${PI_HOST}:${REMOTE_DIR}/design.bin
fi

# Upload kernel driver
echo "📥 Uploading kernel driver..."
scp software/kernel_driver/*.ko ${PI_HOST}:${REMOTE_DIR}/ 2>/dev/null || true

# Upload libraries
echo "📥 Uploading libraries..."
scp software/lib/libfft.so* ${PI_HOST}:${REMOTE_DIR}/ 2>/dev/null || true

# Upload Python modules
echo "📥 Uploading Python modules..."
scp -r software/python/pyfft ${PI_HOST}:${REMOTE_DIR}/ 2>/dev/null || true
scp -r tests/ ${PI_HOST}:${REMOTE_DIR}/ 2>/dev/null || true

# Load bitstream on Pi
if ssh ${PI_HOST} "test -f ${REMOTE_DIR}/design.bin"; then
    echo "⚡ Loading bitstream on Pi..."
    ssh ${PI_HOST} "cd ${REMOTE_DIR} && iceprog design.bin && echo '✅ Bitstream loaded'"
fi

echo "✅ Deployment complete!"
