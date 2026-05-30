#=============================================================================
# ICE40-FFT Development Docker Image
# Based on Debian Bookworm with Project IceStorm + ARM cross-compiler
#
# Build:   docker build -t ice40-fft .
# Run:     docker run --rm -it -v $(pwd):/workspace ice40-fft
#=============================================================================

FROM debian:bookworm-slim

LABEL org.opencontainers.image.title="ICE40-FFT Dev Environment"
LABEL org.opencontainers.image.description="Project IceStorm + ARM cross-compile for ICEZero FPGA"
LABEL org.opencontainers.image.source="https://github.com/your-org/ice40-fft"

ENV DEBIAN_FRONTEND=noninteractive
ENV WORKDIR=/workspace

# ── System Dependencies ───────────────────────────────────────────
RUN apt-get update && apt-get install -y --no-install-recommends \
    # Project IceStorm (open-source FPGA toolchain)
    yosys \
    nextpnr-ice40 \
    \
    # Bitstream tools
    fpga-icestorm \
    iverilog \
    \
    # ARM cross-compiler for Raspberry Pi
    gcc-arm-linux-gnueabihf \
    g++-arm-linux-gnueabihf \
    \
    # Build essentials
    build-essential \
    make \
    git \
    \
    # Python
    python3 \
    python3-pip \
    python3-numpy \
    \
    # Utilities
    curl \
    ca-certificates \
    \
    # GTKWave (VCD viewer)
    gtkwave \
    \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# ── Python Dependencies ──────────────────────────────────────────
RUN pip3 install --break-system-packages --no-cache-dir \
    pytest>=7.0 \
    matplotlib>=3.5

# ── Verify Installations ─────────────────────────────────────────
RUN yosys --version \
    && nextpnr-ice40 --version \
    && arm-linux-gnueabihf-gcc --version | head -1 \
    && python3 --version

# ── Workspace ────────────────────────────────────────────────────
WORKDIR ${WORKDIR}
VOLUME ["${WORKDIR}"]

# ── Default Command ──────────────────────────────────────────────
CMD ["/bin/bash"]
