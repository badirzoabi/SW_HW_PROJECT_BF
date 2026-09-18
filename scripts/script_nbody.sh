#!/usr/bin/env bash
# ============================================================================
# script_nbody.sh — full nbody workflow: baseline -> flame graph -> optimize
#                    -> compare -> correctness check.
# Produces everything under project/results/.
# Run from anywhere: bash scripts/script_nbody.sh
# ============================================================================
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
RESULTS="$ROOT/results"
FG="${FG:-$HOME/FlameGraph}"
PYDBG="$(command -v python3-dbg || command -v python3)"
PY="$(command -v python3)"

mkdir -p "$RESULTS"
cd "$ROOT/nbody"

flamegraph () {   # $1 = perf.data path   $2 = output svg path   $3 = title
    if [ -x "$FG/stackcollapse-perf.pl" ]; then
        perf script -i "$1" 2>/dev/null \
            | "$FG/stackcollapse-perf.pl" \
            | "$FG/flamegraph.pl" --title "$3" > "$2" \
            && echo "   flame graph -> $2"
    else
        echo "   !! FlameGraph not found at $FG — skipping SVG for $2"
    fi
}

echo "############################################################"
echo "# nbody  (results in $RESULTS)"
echo "############################################################"

# ---------------------------------------------------------------------------
# 1) OFFICIAL pyperformance baseline (the command style from the course guide)
# ---------------------------------------------------------------------------
echo "==> [1/6] pyperformance baseline run"
"$PY" -m pyperformance run --bench nbody -o "$RESULTS/nbody_pyperformance_baseline.json" \
    2>&1 | tee "$RESULTS/nbody_pyperformance_baseline.log" || \
    echo "   (pyperformance run failed — we still have the standalone path below)"

# ---------------------------------------------------------------------------
# 2) Standalone ORIGINAL: pyperf timing (clean, reproducible baseline)
# ---------------------------------------------------------------------------
echo "==> [2/6] standalone ORIGINAL timing"
"$PY" nbody_original.py -o "$RESULTS/nbody_orig.json" \
    2>&1 | tee "$RESULTS/nbody_orig.log"

# ---------------------------------------------------------------------------
# 3) perf record + report + flame graph on the ORIGINAL (profiling mode)
# ---------------------------------------------------------------------------
echo "==> [3/6] perf profile ORIGINAL"
NBODY_PROFILE=1 perf record -F 999 -g -o "$RESULTS/nbody_orig.perf.data" -- \
    "$PYDBG" nbody_original.py 2>&1 | tee -a "$RESULTS/nbody_orig.log" || true
perf report --stdio -i "$RESULTS/nbody_orig.perf.data" > "$RESULTS/report_nbody.txt" 2>/dev/null \
    && echo "   perf report -> $RESULTS/report_nbody.txt"
flamegraph "$RESULTS/nbody_orig.perf.data" "$RESULTS/nbody_orig.svg" "nbody original"

# ---------------------------------------------------------------------------
# 4) Standalone OPTIMIZED: pyperf timing
# ---------------------------------------------------------------------------
echo "==> [4/6] standalone OPTIMIZED timing"
"$PY" nbody_optimized.py -o "$RESULTS/nbody_opt.json" \
    2>&1 | tee "$RESULTS/nbody_opt.log"

# ---------------------------------------------------------------------------
# 5) perf profile OPTIMIZED (to show the hotspot shrink in the flame graph)
# ---------------------------------------------------------------------------
echo "==> [5/6] perf profile OPTIMIZED"
NBODY_PROFILE=1 perf record -F 999 -g -o "$RESULTS/nbody_opt.perf.data" -- \
    "$PYDBG" nbody_optimized.py 2>&1 | tee -a "$RESULTS/nbody_opt.log" || true
perf report --stdio -i "$RESULTS/nbody_opt.perf.data" > "$RESULTS/report_nbody_optimized.txt" 2>/dev/null
flamegraph "$RESULTS/nbody_opt.perf.data" "$RESULTS/nbody_opt.svg" "nbody optimized"

# ---------------------------------------------------------------------------
# 6) Compare + correctness (identical output check)
# ---------------------------------------------------------------------------
echo "==> [6/6] compare + correctness"
"$PY" -m pyperf compare_to "$RESULTS/nbody_orig.json" "$RESULTS/nbody_opt.json" \
    2>&1 | tee "$RESULTS/nbody_compare.txt"

E_ORIG="$(NBODY_VERIFY=1 "$PY" nbody_original.py)"
E_OPT="$(NBODY_VERIFY=1 "$PY" nbody_optimized.py)"
echo "final energy original : $E_ORIG" | tee    "$RESULTS/nbody_correctness.txt"
echo "final energy optimized: $E_OPT"  | tee -a "$RESULTS/nbody_correctness.txt"
if [ "$E_ORIG" = "$E_OPT" ]; then
    echo "CORRECTNESS: PASS (identical output)" | tee -a "$RESULTS/nbody_correctness.txt"
else
    echo "CORRECTNESS: check by eye (last-digit FP rounding may differ)" | tee -a "$RESULTS/nbody_correctness.txt"
fi

echo "==> nbody done. See $RESULTS (nbody_compare.txt is the headline number)."
