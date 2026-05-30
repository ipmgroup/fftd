#!/bin/bash
# Sync project files to Raspberry Pi via SSH (rsync)
PI_ADDR=$(cat .config/pi_address.txt 2>/dev/null || echo "rpia5")
PI_USER=$(cat .config/pi_user.txt 2>/dev/null || echo "pi")
rsync -avz --exclude '.venv' --exclude '*.xlsx' --exclude '*.pdf' --exclude 'build/' \
    ./ ${PI_USER}@${PI_ADDR}:/home/${PI_USER}/ice40-fft/
echo "✅ Synced to ${PI_USER}@${PI_ADDR}"
