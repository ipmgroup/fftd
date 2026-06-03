# Build Configuration
# ==================

# Development Machine (x86_64)
HOST_ARCH    := x86_64
HOST_CC      := gcc
HOST_CFLAGS  := -Wall -O2 -g

# Target: Raspberry Pi (ARM)
# Use ARM_CROSS=arm-linux-gnueabihf- for 32-bit (armhf, Pi Zero/1/2/3)
# Use ARM_CROSS=aarch64-linux-gnu-  for 64-bit (aarch64, Pi 3/4/5)
TARGET_ARCH  := armhf
ARM_CROSS    := arm-linux-gnueabihf-
ARM_CROSS64  := aarch64-linux-gnu-
ARM_CC       := $(ARM_CROSS)gcc
ARM_CFLAGS   := -Wall -O2 -march=armv7-a -mfpu=neon
ARM64_CFLAGS := -Wall -O2 -march=armv8-a

# FPGA Target
FPGA_DEVICE  := ice40hx4k
FPGA_PACKAGE := tq144
FPGA_SPEED   := 5

# Remote Raspberry Pi (SSH)
PI_ADDR      ?= $(shell cat .config/pi_address.txt 2>/dev/null || echo rpia5)
PI_USER      ?= $(shell cat .config/pi_user.txt 2>/dev/null || echo pi)
PI_HOST      := $(PI_USER)@$(PI_ADDR)
REMOTE_DIR   := /tmp/ice40-fft

# Open-Source FPGA Toolchain
YOSYS        := yosys
NEXTPNR      := nextpnr-ice40
ICEPACK      := icepack
ICEPROG      := iceprog
IVERILOG     := iverilog
VVP          := vvp
