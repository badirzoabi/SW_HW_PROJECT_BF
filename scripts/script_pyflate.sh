#!/usr/bin/env bash
# script_pyflate.sh — reproduce the pyflate results (run inside the QEMU guest).
# Uses the source captured under pyflate/orig (original, copied from the VM's
# pyperformance install) and pyflate/opt (optimized). Covers: (0) environment
# setup, (1) execution, (2) flame graph + perf data, (3) post-optimization run
# + comparison + byte-identical correctness.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
RESULTS="$ROOT/results"
PYDIR="$ROOT/pyflate"
FG="${FG:-$HOME/FlameGraph}"
PYDBG="$(command -v python3-dbg || command -v python3)"
PY="$(command -v python3)"
mkdir -p "$RESULTS"; cd "$ROOT"

flamegraph () {  # $1=perf.data  $2=out.svg  $3=title
    if [ -x "$FG/stackcollapse-perf.pl" ]; then
        perf script -i "$1" 2>/dev/null | "$FG/stackcollapse-perf.pl" \
            | "$FG/flamegraph.pl" --title "$3" > "$2" && echo "   flame graph -> $2"
    else echo "   !! FlameGraph not at $FG — skipping $2"; fi
}

echo "==> [0/6] environment setup + dependencies"
bash "$HERE/00_setup.sh" || echo "   (setup step skipped/partly failed — continuing)"

echo "==> [1/6] official pyperformance baseline"
"$PY" -m pyperformance run --bench pyflate -o "$RESULTS/pyflate_pyperformance_baseline.json" \
    2>&1 | tee "$RESULTS/pyflate_pyperformance_baseline.log" || echo "   (skipped)"

echo "==> [2/6] ORIGINAL decode timing (pyperf)"
( cd "$PYDIR/orig" && "$PY" run_benchmark.py -o "$RESULTS/pyflate_orig.json" ) \
    2>&1 | tee "$RESULTS/pyflate_orig.log"

echo "==> [3/6] perf profile + flame graph (ORIGINAL, single decode)"
( cd "$PYDIR/orig" && perf record -F 999 -g -o "$RESULTS/pyflate_baseline.perf.data" -- \
    "$PYDBG" run_benchmark.py --worker -l1 -n1 -w0 ) 2>&1 | tee -a "$RESULTS/pyflate_orig.log" || true
perf report --stdio -i "$RESULTS/pyflate_baseline.perf.data" > "$RESULTS/perf_report_pyflate_raw.txt" 2>/dev/null \
    && echo "   perf report -> results/perf_report_pyflate_raw.txt"
flamegraph "$RESULTS/pyflate_baseline.perf.data" "$RESULTS/pyflate_baseline.svg" "pyflate original"

echo "==> [3b] cProfile self-time (derives the Amdahl fraction f for the HW proposal)"
"$PY" "$PYDIR/cprofile_hw_fraction.py" > "$RESULTS/pyflate_cprofile_hw_fraction.txt" 2>&1 \
    && echo "   -> results/pyflate_cprofile_hw_fraction.txt" || echo "   (skipped)"

echo "==> [4/6] OPTIMIZED decode timing (pyperf)"
( cd "$PYDIR/opt" && "$PY" run_benchmark.py -o "$RESULTS/pyflate_opt.json" ) \
    2>&1 | tee "$RESULTS/pyflate_opt.log"

echo "==> [5/6] perf profile + flame graph (OPTIMIZED, single decode)"
( cd "$PYDIR/opt" && perf record -F 999 -g -o "$RESULTS/pyflate_opt.perf.data" -- \
    "$PYDBG" run_benchmark.py --worker -l1 -n1 -w0 ) 2>&1 | tee -a "$RESULTS/pyflate_opt.log" || true
flamegraph "$RESULTS/pyflate_opt.perf.data" "$RESULTS/pyflate_opt.svg" "pyflate optimized"

echo "==> [6/6] before/after comparison + byte-identical correctness"
"$PY" -m pyperf compare_to "$RESULTS/pyflate_orig.json" "$RESULTS/pyflate_opt.json" \
    2>&1 | tee "$RESULTS/pyflate_compare.txt"
"$PY" "$PYDIR/correctness_check.py" 2>&1 | tee "$RESULTS/pyflate_correctness.txt"

echo "==> pyflate done. Headline: results/pyflate_compare.txt"
