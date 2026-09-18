#!/usr/bin/env bash
# ============================================================================
# script_pyflate.sh — pyflate workflow.
#
# pyflate is a pure-Python bzip2/gzip DECOMPRESSOR. Unlike nbody we cannot
# ship a fair "optimized" version blindly: the before/after comparison is only
# valid against the EXACT source installed on this VM. So this script:
#   (1) runs the official pyperformance baseline + flame graph,
#   (2) LOCATES and COPIES the installed pyflate benchmark source into
#       project/pyflate/orig/  and duplicates it to project/pyflate/opt/,
#   (3) runs a standalone baseline from the copied source if possible,
#   (4) prints the exact NEXT STEP for the optimization pass.
#
# Run from anywhere: bash scripts/script_pyflate.sh
# ============================================================================
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
RESULTS="$ROOT/results"
PYDIR="$ROOT/pyflate"
FG="${FG:-$HOME/FlameGraph}"
PYDBG="$(command -v python3-dbg || command -v python3)"
PY="$(command -v python3)"

mkdir -p "$RESULTS" "$PYDIR"

flamegraph () {
    if [ -x "$FG/stackcollapse-perf.pl" ]; then
        perf script -i "$1" 2>/dev/null \
            | "$FG/stackcollapse-perf.pl" | "$FG/flamegraph.pl" --title "$3" > "$2" \
            && echo "   flame graph -> $2"
    else
        echo "   !! FlameGraph not found at $FG — skipping SVG"
    fi
}

echo "############################################################"
echo "# pyflate  (results in $RESULTS)"
echo "############################################################"

# ---------------------------------------------------------------------------
# 1) OFFICIAL pyperformance baseline + perf profile (course-guide style)
# ---------------------------------------------------------------------------
echo "==> [1/4] pyperformance baseline run"
"$PY" -m pyperformance run --bench pyflate -o "$RESULTS/pyflate_pyperformance_baseline.json" \
    2>&1 | tee "$RESULTS/pyflate_pyperformance_baseline.log" || \
    echo "   (pyperformance run failed — will still copy source below)"

echo "==> [1b] perf profile of the pyperformance pyflate run"
perf record -F 999 -g -o "$RESULTS/pyflate_baseline.perf.data" -- \
    "$PYDBG" -m pyperformance run --bench pyflate \
    2>&1 | tee -a "$RESULTS/pyflate_pyperformance_baseline.log" || true
perf report --stdio -i "$RESULTS/pyflate_baseline.perf.data" > "$RESULTS/report_pyflate.txt" 2>/dev/null \
    && echo "   perf report -> $RESULTS/report_pyflate.txt"
flamegraph "$RESULTS/pyflate_baseline.perf.data" "$RESULTS/pyflate_baseline.svg" "pyflate baseline"

# ---------------------------------------------------------------------------
# 2) Locate & copy the installed pyflate benchmark source
# ---------------------------------------------------------------------------
echo "==> [2/4] locating installed pyflate benchmark source"
BM_DIR="$(find / -type d -path '*bm_pyflate*' 2>/dev/null | head -n1)"
PYFLATE_PY="$(find / -type f -name 'pyflate.py' 2>/dev/null | head -n1)"

echo "   bm_pyflate dir : ${BM_DIR:-<not found>}"
echo "   pyflate.py     : ${PYFLATE_PY:-<not found>}"

if [ -n "${BM_DIR:-}" ]; then
    rm -rf "$PYDIR/orig" "$PYDIR/opt"
    cp -r "$BM_DIR" "$PYDIR/orig"
    cp -r "$BM_DIR" "$PYDIR/opt"
    echo "   copied source -> $PYDIR/orig  (and duplicated to $PYDIR/opt)"
elif [ -n "${PYFLATE_PY:-}" ]; then
    mkdir -p "$PYDIR/orig" "$PYDIR/opt"
    cp "$PYFLATE_PY" "$PYDIR/orig/"; cp "$PYFLATE_PY" "$PYDIR/opt/"
    echo "   copied only pyflate.py (no bm_ dir found) -> $PYDIR/orig"
else
    echo "   !! Could not find pyflate source. Is pyperformance installed? (run 00_setup.sh)"
fi

# ---------------------------------------------------------------------------
# 3) Standalone baseline from the copied source, if it has a run_benchmark.py
# ---------------------------------------------------------------------------
echo "==> [3/4] standalone baseline from copied source"
if [ -f "$PYDIR/orig/run_benchmark.py" ]; then
    ( cd "$PYDIR/orig" && "$PY" run_benchmark.py -o "$RESULTS/pyflate_orig.json" ) \
        2>&1 | tee "$RESULTS/pyflate_orig.log" \
        && echo "   standalone baseline -> $RESULTS/pyflate_orig.json"
else
    echo "   (no run_benchmark.py in copied source; use the pyperformance json as baseline)"
fi

# ---------------------------------------------------------------------------
# 4) What to do next (optimization pass)
# ---------------------------------------------------------------------------
cat <<'NEXT'

==> [4/4] NEXT STEP (optimization) — do ONE of these:

  OPTION A (recommended): send the planning assistant these two files so it can
  write the exact, source-matched optimized pyflate:
      - project/pyflate/orig/pyflate.py        (or wherever pyflate.py landed)
      - project/results/report_pyflate.txt     (the profile: shows the hotspots)
      - project/results/pyflate_baseline.svg   (flame graph)

  OPTION B: apply the documented optimization plan yourself in
      project/pyflate/opt/pyflate.py
  (see project/pyflate/OPTIMIZATION_PLAN.txt), then run:
      cd project/pyflate/opt && python3 run_benchmark.py -o ../../results/pyflate_opt.json
      python3 -m pyperf compare_to ../../results/pyflate_orig.json ../../results/pyflate_opt.json

  Either way, the >=7% target is measured with `pyperf compare_to`.
NEXT

echo "==> pyflate baseline + source-collection done."
