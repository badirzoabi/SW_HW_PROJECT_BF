# pyflate Huffman-Decode Accelerator — Hardware Proposal

## 1. What it accelerates & why
pyflate is a pure-Python bzip2/gzip decompressor. Its profile is dominated by
(a) reading the compressed stream **one bit at a time** and (b) **Huffman
decoding** each symbol by walking the code table bit-by-bit — both are tiny
operations executed millions of times through the Python interpreter.

This accelerator turns that inner loop into hardware: a **bit-buffer** front end
feeding a **canonical Huffman decoder** FSM that consumes one bit per cycle and
emits decoded symbols on a stream. Decompression is exactly the "custom
decompression module" example the project spec calls out, and the Huffman stage
is common to both bzip2 and gzip/DEFLATE.

## 2. Top-level block diagram
```
             +-------------------- huffman_accel (top) --------------------+
  AXI4-Lite  |  +-----------+   CTRL/NSYM/STATUS/COUNT + table-load regs    |
  (MMIO)     |  |  Control  |------------------+                            |
 <---------> |  +-----------+                  | tl_we/is_sym/addr/data     |
             |                                  v                            |
 byte stream |  +-----------+  bit   +-------------------------+   symbols   |
 (DMA in) ==>|  | bit_buffer|=======>|    huffman_decoder      |===========> | symbol
  byte_valid |  | 8b->1b MSB| bit_   | code/first/index walk   | osym_valid  | stream
  /ready     |  +-----------+ valid  | cnt[len], symbol[] RAM  | /ready      | (DMA out)
             |                 take   +-------------------------+             |
             +-------------------------------------------------------------+
```

## 3. Interfaces, data widths, I/O
| Port group | Signals | Width | Dir | Notes |
|---|---|---|---|---|
| Clock/Reset | `clk`,`rst_n` | 1 | in | target 300–600 MHz (integer datapath) |
| MMIO | `reg_we`,`reg_addr`,`reg_wdata`,`reg_rdata` | 1/4/32/32 | in/out | AXI4-Lite-style |
| Byte input | `byte_valid`/`byte_ready`,`byte_data` | 1/1/8 | in/out | compressed stream, DMA |
| Symbol output | `osym_valid`/`osym_ready`,`osym` | 1/1/`SYMW`(=9) | out/in | decoded symbols, DMA |

Parameters: `MAXLEN=15` (max code length), `SYMW=9` (symbols 0..511),
`MAXSYM=512`. All integer — fully synthesizable, no FP.

MMIO register map:
| Addr | Name | Meaning |
|---|---|---|
| 0x0 | CTRL | write bit0 = start pulse |
| 0x1 | NSYM | number of symbols to decode this block |
| 0x2 | STATUS | bit0 = busy, bit1 = done |
| 0x3 | COUNT | symbols decoded so far |
| 0x4 | TBL_CNT | load cnt[len]: `wdata[3:0]`=len, `wdata[31:16]`=count |
| 0x5 | TBL_SYM | load symbol[]: `wdata[24:16]`=index, `wdata[8:0]`=symbol |

## 4. Internal architecture (datapath + control)
* **bit_buffer** (`bit_buffer.sv`): 8-bit MSB-first shift register + counter;
  refills a byte when empty (1-cycle bubble every 8 bits), stalls when no input
  byte — providing natural back-pressure.
* **huffman_decoder** (`huffman_decoder.sv`): the standard zlib canonical decode
  as an FSM. Registers `code, first, index, len`; per cycle it folds in one bit,
  compares `code-first` against `cnt[len]`, and either emits
  `symbol[index + (code-first)]` or advances to the next length. Tables
  `cnt[1..MAXLEN]` and `symbol[]` are loaded once per Huffman table over MMIO.
* **Control** (`huffman_accel.sv`): MMIO decodes control/table writes into
  1-cycle pulses; counts emitted symbols; exposes busy/done.

## 5. Hardware/software interface
* **Driver / API.** A CPython C-extension replaces pyflate's per-symbol decode:
  for each Huffman block it programs `cnt[]`/`symbol[]` (built from the code
  lengths pyflate already parses), sets `NSYM`, pulses `start`, DMAs the
  compressed bytes in, and DMAs decoded symbols out. The remaining bzip2 stages
  (MTF, RLE, inverse-BWT) or DEFLATE's LZ77 back-reference copy stay in
  software initially, or become follow-on accelerator stages.
* **Don't break user code** (Accelerator-Patterns rule): the public
  `pyflate.decompress()` API is unchanged; if the device is absent, fall back to
  the pure-Python path.

## 6. Performance / area / power trade-offs
* **Throughput (this design):** ~1 bit/cycle ⇒ ≈ 1/(avg code length) symbols per
  cycle. At 500 MHz and avg ~8-bit codes that is ~60 M symbols/s — vs. the
  Python decode which does a handful of symbols per *microsecond*. Big win, tiny
  area.
* **Faster variant (area/throughput trade):** a lookup-table front end that
  peeks `MAXLEN` bits and indexes a `2^MAXLEN`-entry `{symbol,len}` table decodes
  **1 symbol/cycle**, but costs `2^MAXLEN × (SYMW+4)` bits of table RAM
  (e.g. 15-bit ⇒ 32K entries). A **two-level** table (root table + sub-tables
  for long codes, as zlib does) is the usual compromise: near 1 symbol/cycle
  with far less memory. The serial FSM here is the smallest, always-correct
  baseline.
* **Area:** a handful of registers + adders + comparator + two small RAMs
  (`cnt` ~15×16b, `symbol` ~512×9b). Very small.
* **Frequency:** integer add/compare only — no FP, short critical path ⇒ high
  fmax.
* **Power:** dominated by the small RAMs and the bit-shift; energy per decoded
  symbol is orders of magnitude below the CPU running interpreter bytecodes.
* **Assumptions:** canonical (length-limited) Huffman tables with `MAXLEN≤15`;
  compressed bytes can be DMA-streamed fast enough to keep the FSM fed.

## 7. Files
| File | Role |
|---|---|
| `bit_buffer.sv` | byte→bit MSB-first source with back-pressure |
| `huffman_decoder.sv` | canonical Huffman decode FSM + tables |
| `huffman_accel.sv` | MMIO + streaming top-level wrapper |
| `tb_huffman.sv` | self-checking testbench (3-symbol code → {0,2,1}) |

Simulate:
```
iverilog -g2012 -o sim bit_buffer.sv huffman_decoder.sv tb_huffman.sv && vvp sim
# expect: "TB PASS: decoded {0,2,1} == {0,2,1}"
```

---

# Second-stage accelerator: MTF (Move-To-Front) unit

## Why a second component
Amdahl caps the Huffman/bit accelerator (f = 43.55%) at ~1.77x overall. The next
biggest software hotspot is `move_to_front` (~10.3% of runtime, cProfile) — the
bzip2 stage right after Huffman decode. Accelerating it too raises the covered
fraction to ~53.8% and the estimated overall ceiling to ~2.16x (1/(1-0.538)).
It is the natural next stage of the pipeline (Huffman -> MTF -> RLE -> inverse-BWT).

## What it does / how it works
`mtf_unit.sv` holds the current symbol alphabet in a small register file
(`tbl[0..N-1]`). Each clock it takes an index `idx`, outputs `tbl[idx]`, and moves
that symbol to the front (shifting entries 0..idx-1 down by one) — exactly
software `move_to_front(l, c)`, but with zero list allocation and one symbol/clock.
```
software (per symbol):  l[:] = l[c:c+1] + l[0:c] + l[c+1:]   (4 new lists)
hardware (per clock) :  sym = tbl[idx]; shift tbl[0..idx]; tbl[0] = sym
```

## Interface / I/O
| Port | Width | Dir | Meaning |
|---|---|---|---|
| ld_we, ld_addr, ld_data | 1/AW/W | in | load the alphabet once per block |
| in_valid, idx | 1/AW | in | present an MTF index |
| out_valid, sym | 1/W | out | decoded symbol (1 cycle later) |
Parameters: N=256 (alphabet), W=8 (symbol). Integer-only, fully synthesizable.

## Architecture / trade-offs
- Datapath: N-entry register file with a conditional 1-position shift (each entry
  loads its own or its neighbor's value, gated by i<=idx). Throughput 1 sym/clock.
- Area: N x W register file + N shift muxes (256B + muxes). Bigger than the
  Huffman FSM but still small; the one-cycle 256-wide shift sets timing (a
  multi-cycle or banked shift trades latency for area if fmax is tight).
- Power: dominated by the register-file shift; energy/symbol far below the Python
  list-rebuild it replaces.

## HW/SW interface
Same model as the Huffman engine: MMIO loads the alphabet, DMA streams indices in
and symbols out. On-chip the Huffman engine's symbol stream feeds this unit's idx
input directly (Huffman -> MTF), and MTF output feeds the software RLE/inverse-BWT
(or a future stage).

## Verification
```
iverilog -g2012 -o sim mtf_unit.sv tb_mtf.sv && vvp sim
# expect: "TB PASS: MTF decoded {30,30,60} == {30,30,60}"
```

## Combined estimate (two components)
Huffman+bit (43.55%) + MTF (~10.3%) ≈ 53.8% offloaded -> Amdahl overall ceiling
≈ 1/(1-0.538) ≈ 2.16x (up from ~1.77x with the Huffman engine alone). The
remaining ~46% (inverse-BWT, RLE, control) is the next target.
