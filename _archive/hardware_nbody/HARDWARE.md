# N-body Interaction Accelerator — Hardware Proposal

## 1. What it accelerates & why
The nbody hot loop computes, for every body pair, the same fixed sequence of
floating-point ops: three squares, two adds, a reciprocal-square-root, two
multiplies to cube it, and eight multiplies to scale by `dt` and the two masses.
The flame graph / profile shows essentially all time in this arithmetic +
Python's per-operation interpreter and list-access overhead.

A hardware **N-body Processing Element (PE)** turns that whole per-pair
computation into a single fixed-latency pipeline that accepts **one pair per
clock**. This removes the interpreter overhead entirely and pipelines the FP
math so throughput is one interaction/cycle regardless of the transcendental
`rsqrt` latency.

## 2. Top-level block diagram
```
                +------------------ nbody_accel (top) -------------------+
   AXI4-Lite    |   +-----------+                                        |
  (MMIO regs)   |   |  Control  |  CTRL/DT/STATUS/COUNT registers        |
 <------------> |   |  & Status |                                        |
                |   +-----------+                                        |
                |         | enable, dt                                   |
  AXI4-Stream   |   +-----v------------------------------+   +---------+ |
  pair records  |   |            nbody_pe                |   | output  | |
  {dx,dy,dz,    |==>| sq  sq  sq                          |==>|  FIFO   |==> AXI4-Stream
   mi,mj}       |   |   \  |  /                            |   | (192b)  |   {dvi_xyz,
  s_valid/ready |   |    add-add -> d2 -> rsqrt -> r^3     |   +---------+ |    dvj_xyz}
                |   |      -> *dt -> *mi,*mj -> *d  (x6)   |               |  m_valid/ready
                |   +-------------------------------------+   credit gate  |
                +--------------------------------------------------------+
```

## 3. Interfaces, data widths, I/O
| Port group | Signal(s) | Width | Dir | Notes |
|---|---|---|---|---|
| Clock/Reset | `clk`, `rst_n` | 1 | in | target 300–500 MHz (see §6) |
| MMIO | `reg_we`,`reg_addr`,`reg_wdata`,`reg_rdata` | 1/4/32/32 | in/out | AXI4-Lite-style |
| Input stream | `s_valid`/`s_ready`, `s_dx,s_dy,s_dz,s_mi,s_mj` | 1/1/5×32 | in/out | one pair record |
| Output stream | `m_valid`/`m_ready`, `m_dvi_{x,y,z}`,`m_dvj_{x,y,z}` | 1/1/6×32 | out/in | velocity deltas |

Number format: **IEEE-754 single precision (32-bit)** — the workload is
floating point with wide dynamic range (d² spans ~1 to ~2500, masses ~1e-4·M☉),
so float is the honest choice over fixed point.

MMIO register map:
| Addr | Name | Meaning |
|---|---|---|
| 0x0 | CTRL | bit0 = enable |
| 0x1 | DT | float timestep (default 0.01f) |
| 0x2 | STATUS | bit0 = busy (pipeline/FIFO non-empty) |
| 0x3 | COUNT | pairs completed |

## 4. Internal architecture (datapath + control)
* **Datapath** (`nbody_pe.sv`): 9-stage pipeline of IEEE-754 operators
  `sq→Σ→rsqrt→r²→r³→·dt→·m→·d`. Operands that are needed late (dx/dy/dz, masses,
  dt, r) are carried on matched `delayline` shift registers so every multiply
  sees time-aligned inputs. Latency `LAT = 9`, initiation interval = 1.
* **rsqrt**: modeled here as a 1-cycle operator; a real unit is a LUT seed +
  1–2 Newton-Raphson iterations `y←y·(1.5−0.5·x·y²)` (≈4–6 pipeline stages),
  which only lengthens `LAT`, not the throughput.
* **Control** (`nbody_accel.sv`): credit-based back-pressure — a new pair is
  accepted (`s_ready`) only when `fifo_count + inflight < DEPTH`, so the fixed
  latency pipeline can never overflow the output FIFO. `inflight` tracks pairs
  inside the pipe; `sync_fifo` buffers results for the output stream.

## 5. Hardware/software interface
* **Driver / API.** A thin C driver (or a CPython C-extension replacing the
  Python `advance` inner loop) does: program `DT`, set `CTRL.enable`, then for
  each step **DMA** the pair records into `s_axis` and DMA results back from
  `m_axis`. The host still does the cheap outer work: build the pair list, and
  **accumulate** the returned deltas into each body's velocity
  (`v_i -= dvi`, `v_j += dvj`) and integrate positions.
* **Rule-of-thumb integration** (from the Accelerator-Patterns lecture): user
  Python code is unchanged; only the library/kernel that implements `advance`
  is swapped to call the accelerator. If the device is absent, fall back to the
  software `advance` (don't break user code).
* For only 5 bodies the win is latency-hiding + offload; the design scales to
  large N (that is where an O(N²) offload pays off massively), optionally with
  several PEs in parallel (one pair-stream each) feeding a reduction.

## 6. Performance / area / power trade-offs
* **Throughput:** 1 interaction/cycle after fill. At 400 MHz → 4×10⁸
  interactions/s per PE, vs. millions/s in CPython — orders of magnitude, and
  the transcendental rsqrt is fully pipelined (hidden).
* **Frequency:** the multipliers and the rsqrt Newton stages set fmax; pipelining
  each FP op (as modeled) keeps the critical path to one operator, supporting
  ~300–500 MHz on FPGA / higher on ASIC.
* **Area:** dominated by FP operators — ~3 squares + 2 adds + rsqrt + ~9 more
  mults ≈ a dozen single-precision FP units + delay registers + a small FIFO.
  Modest. Replicating PEs trades area linearly for throughput.
* **Power:** FP multipliers and rsqrt Newton iterations are the energy cost;
  but per *useful* interaction the energy is far below a CPU executing hundreds
  of interpreter bytecodes, so perf/W improves greatly.
* **Assumptions:** single precision is adequate (matches the benchmark's double?
  — see note); DMA bandwidth can sustain 5×32b in + 6×32b out per accepted pair.

## 7. Files
| File | Role |
|---|---|
| `fp_ops.sv` | sim models of the FP IP (mul/add/rsqrt) — replace with vendor IP |
| `nbody_pe.sv` | the pipelined interaction PE + `delayline` |
| `nbody_accel.sv` | MMIO + streaming wrapper + credit control + `sync_fifo` |
| `tb_nbody_pe.sv` | self-checking testbench (vs. shortreal reference) |

Simulate (needs a real-capable SV simulator, e.g. Questa/VCS/Xcelium, or
`iverilog -g2012`):
```
iverilog -g2012 -o sim fp_ops.sv nbody_pe.sv tb_nbody_pe.sv && vvp sim
# expect: "TB PASS: 5 pairs checked, 0 mismatches."
```

> Note on precision: the reference nbody uses Python floats (double). This RTL
> is drawn in single precision for area; the report should state this assumption
> (and that widening to double doubles the FP operator area but not the
> architecture).
