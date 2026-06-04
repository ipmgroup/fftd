#=============================================================================
# ICE40-FFT Development Docker Image
# Ubuntu 24.04 LTS + Project IceStorm toolchain built from source:
#   - YosysHQ/icestorm  (icepack, iceprog, chipdb)
#   - YosysHQ/yosys     (synthesis, requires Python >= 3.11)
#   - YosysHQ/nextpnr   (place & route, ice40 with HX4K-TQ144, cmake >= 3.25)
#
# Build:   docker build -t ice40-fft .
# Run:     docker run --rm -it -v $(pwd):/workspace ice40-fft
#=============================================================================

FROM ubuntu:24.04

LABEL org.opencontainers.image.title="ICE40-FFT Dev Environment"
LABEL org.opencontainers.image.description="Project IceStorm toolchain from source + ARM cross-compile for ICEZero FPGA"
LABEL org.opencontainers.image.source="https://github.com/ipmgroup/fftd"

ENV DEBIAN_FRONTEND=noninteractive
ENV WORKDIR=/workspace

# ── System Dependencies ───────────────────────────────────────────
# Yosys (Ubuntu 24.04): Python 3.12, cmake 3.28, bison 3.8
#   https://yosyshq.readthedocs.io/projects/yosys/en/latest/getting_started/installation.html
# nextpnr: https://github.com/YosysHQ/nextpnr
# icestorm: https://github.com/YosysHQ/icestorm
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential git ca-certificates pkg-config cmake \
    gawk make python3 python3-pip python3-dev lld bison clang flex \
    libffi-dev libfl-dev libreadline-dev tcl-dev zlib1g-dev \
    libboost-all-dev libeigen3-dev \
    libftdi-dev \
    graphviz xdot \
    iverilog \
    gcc-arm-linux-gnueabihf g++-arm-linux-gnueabihf \
    gcc-aarch64-linux-gnu g++-aarch64-linux-gnu \
    python3-pytest python3-matplotlib \
    curl \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# ── ARM64 multiarch: liblgpio for cross-compiling the ICEZero programmer ──
# The C programmer (examples/blinky/icezprog.c) links -llgpio and runs on the
# Pi (aarch64). Enable the arm64 architecture (served from ports.ubuntu.com;
# the default archive.ubuntu.com is amd64/i386 only) and install lgpio for it.
RUN dpkg --add-architecture arm64 && \
    sed -i '/Signed-By: \/usr\/share\/keyrings\/ubuntu-archive-keyring.gpg/i Architectures: amd64' \
        /etc/apt/sources.list.d/ubuntu.sources && \
    printf 'Types: deb\nURIs: http://ports.ubuntu.com/ubuntu-ports/\nSuites: noble noble-updates\nComponents: main universe\nArchitectures: arm64\nSigned-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg\n' \
        > /etc/apt/sources.list.d/arm64.sources && \
    apt-get update && \
    apt-get install -y --no-install-recommends liblgpio-dev:arm64 && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# ── 1. Build icestorm from source (YosysHQ/icestorm) ─────────────
# Must be first: nextpnr needs icestorm chipdb at cmake time
RUN mkdir -p /tmp/build && cd /tmp/build && \
    git clone --depth 1 https://github.com/YosysHQ/icestorm.git && \
    cd icestorm && \
    make -j$(nproc) && \
    make install && \
    rm -rf /tmp/build/icestorm

# ── 2. Build Yosys from source (YosysHQ/yosys) ───────────────────
# Yosys now uses CMake (not legacy Makefile). ABC built-in, no extra flags needed.
RUN mkdir -p /tmp/build && cd /tmp/build && \
    git clone --depth 1 --recursive https://github.com/YosysHQ/yosys.git && \
    cd yosys && \
    cmake -B build && \
    cmake --build build -j$(nproc) && \
    cmake --install build && \
    rm -rf /tmp/build/yosys

# ── 3. Build nextpnr-ice40 from source (YosysHQ/nextpnr) ─────────
# Ubuntu 24.04 ships cmake 3.28 — no pip upgrade needed.
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

# ── Python packages (via apt — Ubuntu 24.04 PEP 668 blocks system pip) ─
# python3-pytest, python3-matplotlib installed above; numpy already a dependency

# ── Verify toolchain ──────────────────────────────────────────────
RUN yosys --version \
    && nextpnr-ice40 --version \
    && icepack -h 2>&1 | head -1 \
    && arm-linux-gnueabihf-gcc --version | head -1 \
    && aarch64-linux-gnu-gcc --version | head -1 \
    && python3 --version \
    && echo "All tools ready"

WORKDIR ${WORKDIR}
VOLUME ["${WORKDIR}"]
CMD ["/bin/bash"]
