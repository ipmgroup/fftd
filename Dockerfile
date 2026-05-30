#=============================================================================
# ICE40-FFT Development Docker Image
# Ubuntu 22.04 LTS + Project IceStorm toolchain built from source:
#   - YosysHQ/icestorm  (icepack, iceprog, chipdb)
#   - YosysHQ/yosys     (synthesis)
#   - YosysHQ/nextpnr   (place & route, ice40 with HX4K-TQ144)
#
# Build:   docker build -t ice40-fft .
# Run:     docker run --rm -it -v $(pwd):/workspace ice40-fft
#=============================================================================

FROM ubuntu:22.04

LABEL org.opencontainers.image.title="ICE40-FFT Dev Environment"
LABEL org.opencontainers.image.description="Project IceStorm toolchain from source + ARM cross-compile for ICEZero FPGA"
LABEL org.opencontainers.image.source="https://github.com/ipmgroup/fftd"

ENV DEBIAN_FRONTEND=noninteractive
ENV WORKDIR=/workspace

# ── System Dependencies ───────────────────────────────────────────
# Yosys (Ubuntu 22.04):
#   https://yosyshq.readthedocs.io/projects/yosys/en/latest/getting_started/installation.html
# nextpnr: https://github.com/YosysHQ/nextpnr
# icestorm: https://github.com/YosysHQ/icestorm
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential git ca-certificates pkg-config cmake \
    gawk make python3 python3-pip lld bison clang flex \
    libffi-dev libfl-dev libreadline-dev tcl-dev zlib1g-dev \
    libboost-all-dev libeigen3-dev \
    libftdi-dev \
    iverilog \
    gcc-arm-linux-gnueabihf g++-arm-linux-gnueabihf \
    curl \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# ── 1. Build icestorm from source (YosysHQ/icestorm) ─────────────
# Must be first: nextpnr needs icestorm chipdb at cmake time
RUN mkdir -p /tmp/build && cd /tmp/build && \
    git clone --depth 1 https://github.com/YosysHQ/icestorm.git && \
    cd icestorm && \
    make -j$(nproc) && \
    make install && \
    rm -rf /tmp/build/icestorm

# ── 2. Build Yosys from source (YosysHQ/yosys) ───────────────────
# Ubuntu 22.04: use clang (recommended). ABC built with -j1 to avoid OOM.
RUN mkdir -p /tmp/build && cd /tmp/build && \
    git clone --depth 1 --recursive https://github.com/YosysHQ/yosys.git && \
    cd yosys && \
    make config-clang && \
    make -j$(nproc) ABCMKARGS="-j1 ABC_USE_NO_READLINE=1" && \
    make install && \
    rm -rf /tmp/build/yosys

# ── Upgrade cmake (Ubuntu 22.04 ships 3.22.1; nextpnr requires ≥ 3.25) ─
RUN pip3 install --no-cache-dir "cmake>=3.25"

# ── 3. Build nextpnr-ice40 from source (YosysHQ/nextpnr) ─────────
# Out-of-tree build required. Uses icestorm chipdb installed in step 1.
RUN mkdir -p /tmp/build && cd /tmp/build && \
    git clone --depth 1 --recurse-submodules https://github.com/YosysHQ/nextpnr.git && \
    cd nextpnr && \
    cmake . -B build \
      -DARCH=ice40 \
      -DBUILD_GUI=OFF \
      -DBUILD_PYTHON=OFF \
      -DBUILD_TESTS=OFF \
      -DICESTORM_INSTALL_PREFIX=/usr/local && \
    cmake --build build -j$(nproc) && \
    cmake --install build && \
    rm -rf /tmp/build/nextpnr

# ── Python packages ───────────────────────────────────────────────
RUN pip3 install --no-cache-dir pytest matplotlib numpy

# ── Verify toolchain ──────────────────────────────────────────────
RUN yosys --version \
    && nextpnr-ice40 --version \
    && icepack -h 2>&1 | head -1 \
    && arm-linux-gnueabihf-gcc --version | head -1 \
    && python3 --version \
    && echo "All tools ready"

WORKDIR ${WORKDIR}
VOLUME ["${WORKDIR}"]
CMD ["/bin/bash"]
