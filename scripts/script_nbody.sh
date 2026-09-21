#!/usr/bin/env bash
# script_nbody.sh — reproduce the nbody results (run inside the QEMU guest).
# Covers the required steps: (0) environment setup, (1) benchmark execution,
# (2) flame graph + perf data, (3) post-optimization run + comparison.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
RESULTS="$ROOT/results"
FG="${FG:-$HOME/FlameGraph}"
PYDBG="$(command -v python3-dbg || command -v python3)"
PY="$(command -v python3)"
mkdir -p "$RESULTS"; cd "$ROOT/nbody"

flamegraph () {  # $1=perf.data  $2=out.svg  $3=title
    if [ -x "$FG/stackcollapse-perf.pl" ]; then
        perf script -i "$1" 2>/dev/null | "$FG/stackcollapse-perf.pl" \
            | "$FG/flamegraph.pl" --title "$3" > "$2" && echo "   flame graph -> $2"
    else echo "   !! FlameGraph not at $FG — skipping $2"; fi
}

echo "==> [0/6] environment setup + dependencies"
bash "$HERE/00_setup.sh" || echo "   (setup step skipped/partly failed — continuing)"

echo "==> [1/6] official pyperformance baseline"
"$PY" -m pyperformance run --bench nbody -o "$RESULTS/nbody_pyperformance_baseline.json" \
    2>&1 | tee "$RESULTS/nbody_pyperformance_baseline.log" || echo "   (skipped)"

echo "==> [2/6] standalone ORIGINAL timing (pyperf)"
"$PY" nbody_original.py -o "$RESULTS/nbody_orig.json" 2>&1 | tee "$RESULTS/nbody_orig.log"

echo "==> [3/6] perf profile + flame graph (ORIGINAL)"
NBODY_PROFILE=1 perf record -F 999 -g -o "$RESULTS/nbody_orig.perf.data" -- \
    "$PYDBG" nbody_original.py 2>&1 | tee -a "$RESULTS/nbody_orig.log" || true
perf report --stdio -i "$RESULTS/nbody_orig.perf.data" > "$RESULTS/perf_report_nbody_raw.txt" 2>/dev/null \
    && echo "   perf report -> results/perf_report_nbody_raw.txt"
flamegraph "$RESULTS/nbody_orig.perf.data" "$RESULTS/nbody_orig.svg" "nbody original"

echo "==> [4/6] standalone OPTIMIZED timing (pyperf)"
"$PY" nbody_optimized.py -o "$RESULTS/nbody_opt.json" 2>&1 | tee "$RESULTS/nbody_opt.log"

echo "==> [5/6] perf profile + flame graph (OPTIMIZED)"
NBODY_PROFILE=1 perf record -F 999 -g -o "$RESULTS/nbody_opt.perf.data" -- \
    "$PYDBG" nbody_optimized.py 2>&1 | tee -a "$RESULTS/nbody_opt.log" || true
perf report --stdio -i "$RESULTS/nbody_opt.perf.data" > "$RESULTS/perf_report_nbody_optimized_raw.txt" 2>/dev/null
flamegraph "$RESULTS/nbody_opt.perf.data" "$RESULTS/nbody_opt.svg" "nbody optimized"

echo "==> [6/6] before/after comparison + correctness"
"$PY" -m pyperf compare_to "$RESULTS/nbody_orig.json" "$RESULTS/nbody_opt.json" \
    2>&1 | tee "$RESULTS/nbody_compare.txt"
E_ORIG="$(NBODY_VERIFY=1 "$PY" nbody_original.py)"
E_OPT="$(NBODY_VERIFY=1 "$PY" nbody_optimized.py)"
{ echo "final energy original : $E_ORIG"; echo "final energy optimized: $E_OPT";
  [ "$E_ORIG" = "$E_OPT" ] && echo "CORRECTNESS: PASS (identical output)" \
      || echo "CORRECTNESS: check (last-digit FP rounding may differ)"; } | tee "$RESULTS/nbody_correctness.txt"

echo "==> nbody done. Headline: results/nbody_compare.txt"
