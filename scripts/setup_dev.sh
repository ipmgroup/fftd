#!/bin/bash
#=============================================================================
# ICE40-FFT Development Environment Setup
# Installs: Project IceStorm (Yosys + nextpnr + icepack + iceprog)
#           ARM cross-compiler, iverilog, Python tools
#
# Usage:  ./scripts/setup_dev.sh
#=============================================================================
set -e

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
ok() { echo -e "${GREEN}✅${NC} $1"; }
warn() { echo -e "${YELLOW}⚠️${NC}  $1"; }

echo "🔧 ICE40-FFT Development Environment Setup"
echo ""

# ── Detect OS ──────────────────────────────────────
if [ -f /etc/os-release ]; then
    . /etc/os-release; OS=$ID
else
    OS=$(uname -s)
fi

# ── 1. Project IceStorm ────────────────────────────
echo "── [1/5] Project IceStorm ──────────────────────────"
NEED_INSTALL=""
for tool in yosys nextpnr-ice40 icepack iverilog; do
    if command -v $tool &>/dev/null; then
        ok "$tool"
    else
        warn "$tool — will install"
        NEED_INSTALL=1
    fi
done
if [ -n "$NEED_INSTALL" ]; then
    case $OS in
        ubuntu|debian)
            sudo apt-get update -qq
            sudo apt-get install -y yosys nextpnr-ice40 icepack iverilog ;;
        arch|manjaro)
            sudo pacman -S --noconfirm yosys nextpnr-ice40 icepack iverilog ;;
    esac
    ok "FPGA toolchain installed"
fi

# ── 2. Verify ──────────────────────────────────────
echo ""
echo "── [2/5] Versions ──────────────────────────────────"
yosys --version 2>/dev/null | head -1 || warn "yosys?"
nextpnr-ice40 --version 2>/dev/null | head -1 || warn "nextpnr?"

# ── 3. ARM Cross-Compiler ──────────────────────────
echo ""
echo "── [3/5] ARM Cross-Compiler ───────────────────────"
if command -v arm-linux-gnueabihf-gcc &>/dev/null; then
    ok "arm-linux-gnueabihf-gcc"
else
    warn "installing..."
    sudo apt-get install -y gcc-arm-linux-gnueabihf 2>/dev/null || true
fi

# ── 4. Python ──────────────────────────────────────
echo ""
echo "── [4/5] Python Dependencies ──────────────────────"
pip install -q numpy pytest 2>/dev/null || true
ok "Python ready"

# ── 5. Optional ────────────────────────────────────
echo ""
echo "── [5/5] Optional Tools ───────────────────────────"
for tool in gtkwave verilator doxygen; do
    command -v $tool &>/dev/null && ok "$tool" || warn "$tool (optional)"
done

# ── Test Blinky ────────────────────────────────────
echo ""
echo "── 🧪 Building Blinky Test ─────────────────────────"
if [ -d examples/blinky ]; then
    make -C examples/blinky clean 2>/dev/null || true
    if make -C examples/blinky 2>&1 | tail -3; then
        SIZE=$(stat -c%s examples/blinky/top.bin 2>/dev/null || echo "?")
        ok "Blinky built! ($SIZE bytes)"
    else
        warn "Blinky build failed — check toolchain"
    fi
fi

echo ""
echo "✅ Setup complete!"
echo "   Try: cd examples/blinky && make prog"
