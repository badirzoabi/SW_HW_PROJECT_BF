# HW/SW Co-design Project (00460882) — nbody + pyflate

Benchmark optimization and profiling for two `pyperformance` benchmarks —
**nbody** and **pyflate** — plus a hardware-acceleration proposal for pyflate.

> **Course clarification (2026-09-18):** the spec requires a hardware
> accelerator for "one or two key components of *the* benchmark" — i.e. at
> least one benchmark, not necessarily both. This submission features **one**
> accelerator, on **pyflate**; nbody is software-only. See `CHANGES.md`.

## Repository structure

```
project/
├── CHANGES.md                   # what changed after the course clarification, and why
├── README.md                    # this file
├── prompt.txt                   # log of AI prompts used (required deliverable)
├── report_nbody.txt             # course-required report (overview/analysis/opt) — software-only
├── report_pyflate.txt           # course-required report (overview/analysis/opt/hw + Amdahl estimate)
├── scripts/
│   ├── 00_setup.sh              # one-time environment setup (run inside the VM)
│   ├── script_nbody.sh          # nbody: baseline → profile → optimize → compare
│   └── script_pyflate.sh        # pyflate: setup → orig/opt run → compare → correctness
├── nbody/
│   ├── nbody_original.py        # unmodified pyperformance nbody
│   └── nbody_optimized.py       # optimized nbody (scalar-locals force loop)
├── pyflate/
│   ├── OPTIMIZATION_PLAN.txt     # optimization recipe used for pyflate
│   ├── correctness_check.py      # standalone byte-for-byte orig vs opt diff/MD5 check
│   ├── cprofile_hw_fraction.py   # derives the Amdahl f used in report_pyflate.txt §5
│   ├── orig/run_benchmark.py     # untouched source copied from the VM (pyperformance's
│   │                              # bm_pyflate — this version has no separate pyflate.py)
│   └── opt/run_benchmark.py      # optimized version (buffered bit reader, in-place MTF,
│                                  # table-driven Huffman decode)
├── hardware/                     # SystemVerilog accelerator proposal (simulated OK)
│   └── pyflate/                  # two-component accelerator: Huffman engine + MTF unit
│       ├── bit_buffer.sv  huffman_decoder.sv  huffman_accel.sv  tb_huffman.sv
│       ├── mtf_unit.sv  tb_mtf.sv   HARDWARE.md
├── _archive/
│   └── hardware_nbody/           # nbody's N-body PE design — not part of this submission's
│                                  # graded HW deliverable, kept for reference (see CHANGES.md)
└── results/                     # all reports, flame graphs, json, logs from the real VM run
```

## How to reproduce (inside the QEMU guest)

```bash
cd project
bash scripts/00_setup.sh          # perf, python3-dbg, pyperf, pyperformance, FlameGraph
bash scripts/script_nbody.sh      # produces results/nbody_compare.txt etc.
bash scripts/script_pyflate.sh    # produces results/pyflate_compare.txt, flame graphs, correctness
```

All work must run **inside the QEMU guest**, not on the host server.

## nbody — the optimization

nbody has a fixed, tiny working set (5 bodies). The original keeps every body's
position/velocity in Python **lists** and re-unpacks a tuple of pairs each
iteration, so the hot force loop pays for list subscripting (`v1[0] -= ...`) and
nested unpacking on every step.

The optimized version specializes the force loop into **straight-line code over
local scalars** (`x0,y0,z0,vx0,...`), reading the body lists once at entry and
writing back once at exit. Local variables use fast `LOAD_FAST/STORE_FAST` slots
instead of subscripting heap list objects — the software analogue of register
allocation.

```
original :  list-based, tuple-unpacked pair loop   (v1[0] -= dx*b2m ; ...)
optimized:  scalar locals, straight-line, no per-iteration indexing/unpacking
```

Same physics, **identical printed output** (verified to 9 decimals), measured
**~1.5× / ~36% faster** in pure CPython — well past the 7% bar. (Note: replacing
the `x ** -1.5` power with a hardware `sqrt` was tried first and made ~no
difference — the bottleneck is interpreter/memory overhead, not the FPU. This is
exactly the kind of "measure, don't assume" result the report should highlight.)

## pyflate — the optimization

pyflate is a pure-Python bzip2/gzip decompressor. Because a fair before/after
comparison must be made against the **exact** source installed on the VM,
`script_pyflate.sh` copies that source (`pyperformance`'s `bm_pyflate` package —
a single self-contained `run_benchmark.py`, no separate `pyflate.py` module in
this version) into `pyflate/orig` and `pyflate/opt`.

Profiling (`perf` + flame graph on the debug Python build) showed the dominant
cost, after raw bytecode dispatch, was CPython **allocator/object-churn**
overhead (`_PyMem_DebugCheckAddress`, `list_dealloc`, `memset`) rather than any
single arithmetic line — traced to three hot spots:

```
move_to_front():        l[:] = l[c:c+1] + l[0:c] + l[c+1:]   # 3 new lists + concat, every MTF symbol
RBitfield._more():       self.f.read(1) + ord(c)              # one Python file-read per byte, millions of times
HuffmanTable.find_next_symbol():  linear scan over the whole sorted code table, every decoded symbol
```

Fixes applied in `pyflate/opt/run_benchmark.py` (algorithm and all other lines
byte-identical to `orig/`):
1. **Buffered bit reader** — `RBitfield` reads the whole input into memory once
   and indexes into it directly, instead of a live file object per byte.
2. **In-place move-to-front** — `del l[c]; l.insert(0, v)` instead of building
   and concatenating three new list slices.
3. **Table-driven Huffman decode** — a precomputed `2**max_bits`-entry direct
   lookup table (capped at `max_bits<=15`) turns each symbol decode into one
   array index instead of an O(table size) scan; falls back to the original
   scan for the untouched gzip path and any oversized table.

Verified byte-for-byte identical output against `orig/` (MD5
`afa004a630fe072901b1d9628b960974` on both sides), measured
**1.50× / ~33% faster** via `pyperf compare_to` — well past the 7% bar. See
`report_pyflate.txt` for the full writeup.

## Hardware accelerator (SystemVerilog) — pyflate only

`hardware/pyflate/` is a **two-component**, integer-only, fully-synthesizable
accelerator for the two hottest, most hardware-friendly bzip2 stages
(Huffman → MTF → RLE → inverse-BWT), both **passing self-checking simulation**
(Icarus Verilog `iverilog -g2012`):
- **(A) bit-reader + Huffman decode engine** (`bit_buffer.sv`, `huffman_decoder.sv`,
  `huffman_accel.sv`, `tb_huffman.sv`): `TB PASS: decoded {0,2,1} == {0,2,1}`.
- **(B) Move-To-Front unit** (`mtf_unit.sv`, `tb_mtf.sv`): `TB PASS: MTF decoded {30,30,60}`.
On-chip they chain (Huffman symbol stream → MTF index), so the CPU isn't in the
loop between stages. `HARDWARE.md` has both block diagrams, I/O tables, register
map, HW/SW interface, and area/power/perf trade-offs.

**Estimated overall speedup (Amdahl's Law).** The accelerator is a design
proposal — per the spec, not synthesized or run — so its effect on *overall*
program time is an estimate: `1 / ((1-f) + f/s)`. `f` was derived rigorously
with `cProfile` on the original decoder (self-time bucketing):
- Component (A) covers **f = 43.55%** (bit-reading 27.70% + Huffman 15.85%); with
  `s ≈ 3,100×` this alone gives **~1.77×** (and even `s → ∞` only reaches
  `1/(1-f) ≈ 1.77×`, so it's robust to `s`).
- Adding component (B), the MTF stage (**~10.3%** of runtime), raises the covered
  fraction to **~53.8%** and the estimated overall ceiling to **~2.16×**.
- The residual ~46% (inverse-BWT, RLE, control) sets the next ceiling → inverse-BWT
  is the logical third stage. Full derivation in `report_pyflate.txt` §5.

nbody's hardware proposal (a pipelined N-body Processing Element, one
pair/clock, `TB PASS: 5 pairs checked, 0 mismatches.`) is not part of this
submission's graded hardware deliverable — see `_archive/hardware_nbody/`.

## Results summary

| Benchmark | Original | Optimized | Speedup | Correctness |
|---|---|---|---|---|
| nbody   | 3.93s ± 0.38s  | 2.50s ± 0.22s  | **1.58×** | identical final energy (9 decimals) |
| pyflate | 17.6s ± 1.3s   | 11.7s ± 0.9s   | **1.50×** | byte-identical output (MD5 match) |

Plus, for pyflate only: an **estimated ~2.16× overall speedup** from the
two-component hardware accelerator (Amdahl's Law: covered fraction ~53.8% =
Huffman/bit 43.55% + MTF ~10.3%; component (A) alone ~1.77× — see above).

Both software figures measured via the official `pyperf compare_to` protocol inside the course
QEMU guest (see `results/nbody_compare.txt` and `results/pyflate_compare.txt`).
Note: the guest ran under software CPU emulation (no nested-KVM on this course
account), so absolute times are inflated vs. bare metal — the relative
before/after comparison is unaffected since both sides of each comparison ran
on the same guest.

## Still to come

- 20–25 min presentation.
