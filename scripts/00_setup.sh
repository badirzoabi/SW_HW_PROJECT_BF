#!/usr/bin/env bash
# ============================================================================
# 00_setup.sh  —  One-time environment setup INSIDE the QEMU guest.
# Run this FIRST (as root, which is the default VM user).
# ============================================================================
set -u  # (intentionally NOT -e: we want to continue past optional failures)

echo "==> HW/SW project setup starting"

# --- 0. Where are we? Sanity: we must be inside the VM, not the host server ---
echo "==> hostname: $(hostname)   whoami: $(whoami)   kernel: $(uname -r)"
echo "    (If this is a naranja* server prompt, STOP: start QEMU and log into the guest first.)"

SUDO=""
if [ "$(id -u)" -ne 0 ]; then SUDO="sudo"; fi

# --- 1. Allow perf to read hardware counters ---
if [ -w /proc/sys/kernel/perf_event_paranoid ]; then
    echo -1 > /proc/sys/kernel/perf_event_paranoid || true
fi
$SUDO sysctl -w kernel.perf_event_paranoid=-1 2>/dev/null || true
$SUDO sysctl -w kernel.kptr_restrict=0        2>/dev/null || true

# --- 2. Packages: perf, debug Python, pip, git, perl (for FlameGraph) ---
export DEBIAN_FRONTEND=noninteractive
$SUDO apt-get update -y || true
$SUDO apt-get install -y \
    linux-tools-common "linux-tools-$(uname -r)" linux-tools-generic \
    python3-dbg python3-pip git perl bzip2 || true

# --- 3. Python profiling / benchmarking tooling (install for BOTH interpreters) ---
python3     -m pip install --upgrade pip pyperf pyperformance || true
python3-dbg -m pip install --upgrade pip pyperf pyperformance || true

# --- 4. Brendan Gregg's FlameGraph scripts ---
FG="${FG:-$HOME/FlameGraph}"
if [ ! -d "$FG" ]; then
    git clone https://github.com/brendangregg/FlameGraph "$FG" || \
        echo "!! FlameGraph clone failed (no network?). Copy it in manually to $FG"
fi

# --- 5. Report what we have ---
echo "==> versions:"
perf --version                 || echo "   perf: MISSING"
python3 --version              || true
python3-dbg --version          || true
python3 -m pyperf --version    || true
python3 -m pyperformance --version 2>/dev/null || true
ls "$FG"/flamegraph.pl "$FG"/stackcollapse-perf.pl 2>/dev/null \
    && echo "   FlameGraph: OK" || echo "   FlameGraph: MISSING (set FG=/path)"

echo "==> setup done. Next: bash scripts/script_nbody.sh"
