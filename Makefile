# ICE40-FFT Project — Top-Level Makefile
# https://github.com/your-org/ice40-fft

include config.mk

.PHONY: all clean synth sim arm-lib arm-driver deploy test-remote \
        docker-build docker-shell docker-synth docker-blinky docker-all help

all: synth arm-lib arm-driver

# ── FPGA Synthesis ──────────────────────────────────
synth:
	$(MAKE) -C hardware/synth synth_ice40

# ── Simulation ──────────────────────────────────────
sim:
	$(MAKE) -C hardware/sim

# ── ARM Cross-Compile ───────────────────────────────
arm-lib:
	$(MAKE) -C software/lib ARM_CROSS=$(ARM_CROSS) KERNEL_SRC=$(KERNEL_SRC)

arm-driver:
	$(MAKE) -C software/kernel_driver ARM_CROSS=$(ARM_CROSS)

# ── Deploy & Remote Test ────────────────────────────
deploy:
	./scripts/deploy_to_pi.sh

test-remote:
	./scripts/test_on_pi.sh

# ── Clean ───────────────────────────────────────────
clean:
	$(MAKE) -C hardware/synth clean
	$(MAKE) -C hardware/sim clean
	$(MAKE) -C software/lib clean
	$(MAKE) -C software/kernel_driver clean

help:
	@echo "Available targets:"
	@echo "  make synth        — Synthesize FPGA bitstream (Yosys + nextpnr)"
	@echo "  make sim          — Run RTL simulation (iverilog/Verilator)"
	@echo "  make arm-lib      — Cross-compile libfft.so for ARM"
	@echo "  make arm-driver   — Cross-compile fft_driver.ko for ARM"
	@echo "  make deploy       — Deploy to Raspberry Pi via SSH"
	@echo "  make test-remote  — Run tests on Pi via SSH"
	@echo "  make all          — synth + arm-lib + arm-driver"
	@echo "  make clean        — Clean all build artifacts"
	@echo ""
	@echo "Docker targets:"
	@echo "  make docker-build — Build Docker image"
	@echo "  make docker-shell — Interactive shell in container"
	@echo "  make docker-synth — Synthesize FPGA in Docker"
	@echo "  make docker-blinky— Build blinky test in Docker"
	@echo "  make docker-all   — Full build in Docker"

# ── Docker ──────────────────────────────────────────
docker-build:
	docker compose build

docker-shell:
	docker compose run --rm dev

docker-synth:
	docker compose run --rm synth

docker-blinky:
	docker compose run --rm blinky

docker-sim:
	docker compose run --rm sim

docker-arm-lib:
	docker compose run --rm arm-lib

docker-arm-driver:
	docker compose run --rm arm-driver

docker-all:
	docker compose run --rm dev make all
