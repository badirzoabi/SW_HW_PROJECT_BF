# CHANGES — course clarification update (2026-09-18)

## What changed

**Hardware acceleration is now featured on pyflate only. nbody is
software-only.**

- The spec (Project.pdf p.4, item 7) requires a hardware accelerator for "one
  or two key components of *the* benchmark" — read as: at least **one**
  benchmark needs an accelerator, not both.
- The previously-built **nbody** hardware accelerator (N-body Processing
  Element, `TB PASS: 5 pairs checked, 0 mismatches.`) was removed from the
  graded submission and moved to `_archive/hardware_nbody/` — kept intact for
  reference, not deleted.
- **pyflate** keeps its hardware accelerator (Huffman decode engine,
  `TB PASS: decoded {0,2,1} == {0,2,1}`).
- **Both benchmarks' software optimizations are unchanged** — already
  measured and reported: nbody 1.58×/36.5%, pyflate 1.50×/33.3%, both
  correctness-verified.

## What was added: the hardware "performance effect"

The spec expects the hardware proposal to include a performance effect, but
the accelerator is a design proposal only — per the spec it is not
synthesized or physically run. Its effect on the *benchmark's overall*
runtime is therefore an **estimate**, computed with Amdahl's Law:

```
overall_speedup = 1 / ((1 - f) + f/s)
```

- `f` = the fraction of total original-decoder runtime spent in the part the
  accelerator replaces (bit-reading + Huffman symbol matching).
- `s` = the per-component speedup the hardware gives that fraction.

**How `f` was derived.** `perf`'s raw report only resolves to C-level symbol
names, which can't be cleanly split into "time in Huffman decode" vs. "time in
BWT/MTF/RLE." Instead, `pyflate/orig/run_benchmark.py` (unmodified) was run
under Python's own `cProfile` on a single real decode of the benchmark's
actual input file (script: `pyflate/cprofile_hw_fraction.py`), and self-time
(`tottime` — excludes sub-calls, so bit-reading time inside a Huffman lookup
isn't double-counted) was bucketed:

| Bucket | Self-time |
|---|---|
| bit-reading (`RBitfield.readbits/needbits/_more/snoopbits/_read`) | 27.70% |
| Huffman match (`HuffmanTable.find_next_symbol`) | 15.85% |
| **f (combined)** | **43.55%** |

Everything else — `decode_huffman_block`'s own loop/MTF-dispatch code,
`move_to_front`, `bwt_reverse`/`bwt_transform`, RLE — stays software either
way, matching the accelerator's stated scope.

**How `s` was derived.** 148,271 Huffman symbols were decoded in that run.
Scaling cProfile's bucketed time to the real `pyperf`-measured original
runtime (17.6s mean) gives a software rate of ~19,300 symbols/s for that
component; the hardware design's own estimate is ~60,000,000 symbols/s
(500 MHz, ~8-bit average code length) → `s ≈ 3,100×`.

**Result:** `overall_speedup ≈ 1/((1-0.4355) + 0.4355/3100) ≈ 1.77×`. Because
`s` is so large, this is almost entirely determined by `f` — even an
infinitely fast accelerator only reaches `1/(1-f) ≈ 1.77×` — so the estimate
is robust to exactly how fast the FSM itself is. Full derivation, with the
sensitivity check, is in `report_pyflate.txt` §5.

## Files touched

- `report_nbody.txt` — hardware section replaced with a note pointing to
  pyflate's accelerator and the archive.
- `report_pyflate.txt` — hardware section extended with the Amdahl estimate
  and its full derivation; conclusion updated to cite it.
- `README.md` — repository structure and hardware sections updated.
- `hardware/nbody/` → moved to `_archive/hardware_nbody/`.
- `pyflate/cprofile_hw_fraction.py` — new; the script used to derive `f`.
- `prompt.txt` — new entry logging this update.
