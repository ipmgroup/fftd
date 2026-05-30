#!/bin/bash
# Run integration tests on Raspberry Pi via SSH
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_DIR"

PI_ADDR=$(cat .config/pi_address.txt 2>/dev/null || echo "rpia5")
PI_USER=$(cat .config/pi_user.txt 2>/dev/null || echo "pi")
PI_HOST="${PI_USER}@${PI_ADDR}"
REMOTE_DIR="/tmp/ice40-fft"

echo "🧪 Running tests on ${PI_HOST}..."

# Load kernel driver
echo "📍 Loading kernel driver..."
ssh ${PI_HOST} "cd ${REMOTE_DIR} && sudo insmod fft_driver.ko && echo '✅ Driver loaded'" || {
    echo "⚠️  Driver load failed (may already be loaded)"
}

sleep 1

# Run Python tests
echo "🧪 Running Python tests..."
ssh ${PI_HOST} "cd ${REMOTE_DIR} && PYTHONPATH=. python3 -m pytest tests/ -v" || true

# Unload driver
echo "📍 Unloading kernel driver..."
ssh ${PI_HOST} "sudo rmmod fft_driver 2>/dev/null || true"

echo "✅ Tests complete!"
