#!/bin/bash
# Open SSH shell to Raspberry Pi
PI_ADDR=$(cat .config/pi_address.txt 2>/dev/null || echo "rpia5")
PI_USER=$(cat .config/pi_user.txt 2>/dev/null || echo "pi")
ssh ${PI_USER}@${PI_ADDR}
