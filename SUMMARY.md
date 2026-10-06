# Pipelined Heap Priority Queue — Project Summary

Hardware priority queue (pipelined binary min-heap) after Ioannou & Katevenis,
IEEE/ACM ToN 15(2) 2007, version (ii): one stage per level, 2-port 4-wide
memories, 1-level/cycle ripple. 16K-class capacity (16383 entries, 14 levels),
32-bit keys + 16-bit IDs, pure Verilog-2001.

**Status: complete.** Functionally verified on the final RTL (6 seeds,
6,303,190 ops, 0 errors); throughput spec met and measured; synthesis + P&R
closed on three parts. The 250 MHz timing goal was **not** met — see Results
for the achieved frequencies and ARCHITECTURE.md §10 for why.

## What was built

```
rtl/pheap.v      top + all stage logic (generate blocks) - synthesizable V2001
rtl/ram_dp.v     inferable SDP BRAM template (sync read, registered output)
tb/tb_pheap.v    self-checking TB: software-heap reference + per-ID multiset,
                 directed smoke/hazard suites, 1M-op randomized regression,
                 throughput measurement + protocol assertions
sim/             Makefile (make -C sim quick|full|regress) and run.ps1
syn/             yosys_check.ys, timing.xdc, vivado_ooc.tcl (default flow),
                 vivado_ooc_aggr.tcl (timing-aggressive directives);
                 both take <part> [<period_ns>] via -tclargs
docs/            ARCHITECTURE.md (design), NOTES.md (hazard/bug log)
```

## How to run

```
# simulation (Icarus Verilog; OSS CAD Suite on PATH or see sim/run.ps1)
iverilog -g2005 -o sim/tb.vvp -s tb_pheap tb/tb_pheap.v rtl/pheap.v rtl/ram_dp.v
vvp sim/tb.vvp +quick +seed=1        # ~200k ops, minutes
vvp sim/tb.vvp +seed=101             # full ~1M-op regression

# synthesizability lint
yosys -s syn/yosys_check.ys

# Vivado OOC synth+P&R (batch); period defaults to 4.0 ns
vivado -mode batch -source syn/vivado_ooc.tcl      -tclargs <part> [<period_ns>]
vivado -mode batch -source syn/vivado_ooc_aggr.tcl -tclargs <part> [<period_ns>]
```

## Results

### Functional verification

Reference model: software binary heap over keys plus a per-ID key table, so
duplicate keys are checked as a multiset. Every accepted op is checked; the TB
also asserts the protocol (that `ready_ins`/`ready_del` are high whenever the
spec requires), so any stall would fail the test rather than silently slow the
design down.

| Seed | Ops checked | Errors |
|---|---|---|
| 101 | 1,050,532 | 0 |
| 202 | 1,050,532 | 0 |
| 303 | 1,050,532 | 0 |
| 404 | 1,050,530 | 0 |
| 505 | 1,050,532 | 0 |
| 606 | 1,050,532 | 0 |
| **total** | **6,303,190** | **0** |

(Seed 404 issues two fewer ops than the others — the randomized phases are
op-count-driven but the closing drain length depends on the residual heap
contents, so per-seed totals differ slightly.)

Directed coverage feeding those runs: fill/drain ascending, descending,
duplicate and extreme keys, fill-to-full (16383), empty/full ready rejection,
ready-rule bubble checks, I-I chases, D-bubble-D chases (paper Fig. 6),
insert-abort at every depth (gap sweep 0..28 plus multi-insert chains), m=0
delete chains across every level boundary, constant-key tie storms, and
landing-at-delete sweeps. Randomized phases run at the maximum legal rate off
`ready_*` with four weightings (insert-heavy, balanced, delete-heavy,
narrow-key). Logs: `sim/run_s101.log` … `sim/run_s606.log`.

### Measured throughput (asserted in the TB, not just observed)

| Pattern | Measured | Spec |
|---|---|---|
| Sustained insert | 10000 ops / 10000 cycles = **1.000000** ops/cycle | 1 insert/cycle |
| Alternating delete/insert | 10000 ops / 10000 cycles = **1.000000** ops/cycle | 1 op/cycle |
| Sustained delete drain | 10000 ops / 19999 cycles = **0.500025** ops/cycle | 1 delete / 2 cycles |

Delete result latency is a fixed 1 cycle after accept.

### Timing (post-route, out-of-context)

Target was 250 MHz (4.0 ns). **Not achieved.** Achieved closure:

The closing-period rows below were characterized on the RTL immediately prior to
the `count_next` candidate precompute. That precompute is bit-exact and
timing-neutral (a1 @4 ns: −8.169 vs −8.138, within run-to-run noise), so the
closures hold for the shipped RTL; the two are functionally identical.

| Part | Flow | Period | WNS | Closes | Achieved Fmax |
|---|---|---|---|---|---|
| xc7a100tcsg324-1 | default | 4.000 | −8.138 | no | — |
| xc7a100tcsg324-1 | default | 12.000 | −0.413 | no | — |
| xc7a100tcsg324-1 | default | 12.600 | −0.430 | no | — |
| xc7a100tcsg324-1 | default | 14.000 | −0.835 | no | — |
| **xc7a100tcsg324-1** | **aggressive** | **12.500** | **+0.035** | **yes** | **80.2 MHz** |
| **xc7a100tcsg324-2** | **aggressive** | **10.500** | **+0.006** | **yes** | **95.3 MHz** |
| xc7k160tfbg484-3 | default | 4.000 | −1.938 | no | — |
| xc7k160tfbg484-3 | default | 6.000 | −0.120 | no | — |
| xc7k160tfbg484-3 | default | 6.200 | −0.064 | no | — |
| xc7k160tfbg484-3 | default | 6.500 | +0.042 | yes | 154.8 MHz |
| xc7k160tfbg484-3 | aggressive | 6.000 | +0.067 | yes | 168.5 MHz |
| xc7k160tfbg484-3 | aggressive | 5.700 | +0.027 | yes | 176.3 MHz |
| **xc7k160tfbg484-3** | **aggressive** | **5.400** | **+0.004** | **yes** | **185.3 MHz** |

Fmax = 1000/(period − WNS), quoted only for runs where WNS ≥ 0. "aggressive" =
`syn/vivado_ooc_aggr.tcl` (synth `-retiming -flatten_hierarchy rebuilt`,
`place_design -directive ExtraTimingOpt`, `phys_opt`/`route -directive
AggressiveExplore`, second `phys_opt` pass).

Two honest caveats on the numbers above:

* **The default flow's period sweep never crosses zero on the -1 part.** Vivado
  rebuilds this design *worse* as the constraint relaxes — the worst cone is 16
  levels / 4.74 ns of logic at a 4 ns constraint but 18 levels / 5.86 ns at 14 ns
  — so slack degrades from −0.413 (12 ns) to −0.835 (14 ns). The closing periods
  had to be found with the aggressive directives, which hold effort up.
* **Small hold violations are reported in every run** (a1 WHS −0.117 / 97
  endpoints, k3 −0.008 / 19 endpoints). These are an out-of-context clocking
  artifact: the reports show 0.000 ns source clock delay against ~0.5 ns
  destination clock delay because no BUFG is inserted in OOC mode. On a
  buffered clock in a real design context they do not apply, and Vivado's
  hold-fixing would absorb them; no setup path was traded to obtain them.

### Utilization (post-route)

| | xc7a100tcsg324-1 @12.5 ns | xc7k160tfbg484-3 @5.4 ns |
|---|---|---|
| Slice LUTs | 13,210 (20.8 %) | 13,450 (13.3 %) |
| Slice Registers | 7,201 (5.7 %) | 7,490 (3.7 %) |
| Block RAM tiles | 38 (28.2 %) — 36×RAMB36 + 4×RAMB18 | 38 (11.7 %) |

The design is not congested on either part; the timing limit is path structure,
not resource pressure.

### Why the frequency target was missed

Detailed in ARCHITECTURE.md §10 and NOTES.md passes 5–7. The limit is a
*family* of near-identical route-dominated cones (74–76 % routing), not one
fixable path: the delete-refill gather (`rw1q`/`count_r` → per-stage compares →
`refill_r`) and the insert address path (`ins_k_r` → variable shift → BRAM
write-enable), which differ by <0.1 ns. The refill value is a **one-cycle 14→1
reduction** whose sources are registers sitting next to their BRAMs, and every
pipeline level owns banks in all four BRAM columns — so the sources are
necessarily spread across the full die width. No single flip-flop can be placed
near 14 die-spread sources; the spread is logical, not placement sloppiness.

A three-pass timing campaign confirmed this empirically:

| Attempt | What | Result |
|---|---|---|
| `vpipe`/`cwr` mirrors | move the 48-bit traveling buses out of the gather | bit-exact; WNS +0.078 ns (noise) |
| `count_next` candidate precompute | register-feed the compares, drop the 15-bit incrementer from the cone | bit-exact (6-seed); logic 16→13 levels but route 60→74 %; **WNS net-neutral** |
| floorplan pblock (half-die) | compact the core to shorten routes | **worse** (−8.169 → −8.921): BRAM-column congestion |

Logic retiming and placement are therefore **exhausted**. The only remaining
lever is architectural: give the 14→1 refill gather its own pipeline stage so
no single cycle crosses the die (register the per-stage hit bits mid-path,
uniform +1 stage on both op types, delete result = `min(root, pending stage-0
insert)` to preserve 1-cycle latency). This is a full control-plane redesign
with no verifiable intermediate state; it is **designed but not implemented** —
see `docs/PLUS1_STAGE.md`. Expected ceiling even so is ~130–160 MHz on the -1
fabric, i.e. 250 MHz is not reachable on this part without a different
microarchitecture. Per spec §7 the achieved rates were never traded for
frequency.

## Interface & latency

* `op`: 00 NOP / 01 INSERT / 10 DELETE_MIN, one per cycle, gated by
  `ready_ins` / `ready_del`.
* Delete result: `del_valid/del_key/del_id` registered, exactly 1 cycle after
  the delete is accepted.
* `ready_del` deasserts for exactly one cycle after each accepted delete and
  when empty; `ready_ins` deasserts only when full. Sustained: 1 insert/cycle,
  1 delete per 2 cycles, insert-after-anything and delete-after-insert legal
  back-to-back (the insert is aborted per the paper).

## Known limitations & deviations

* Capacity 16383 = 2^14-1 (complete tree), not 16384.
* `replaceMin` not implemented (matches the paper's own implementation).
* Plain unsigned key comparison (no wrap-around compare).
* Stage logic lives in generate blocks in `pheap.v` instead of separate
  per-stage files (justification in docs/NOTES.md).
* **The literal target part `xc7z020clg400-1` was never run.** The Vivado 2025.1
  install on this machine has no Zynq-7000 device support (only Artix-7,
  Kintex-7, Virtex-7, Spartan-7), and adding it requires an AMD-account
  download. Proxies used: `xc7a100tcsg324-1` (the 7z020's PL *is* Artix-7
  fabric at the same -1 speed grade, so this is the representative number),
  `xc7a100tcsg324-2` (≈ a 7z020-2's fabric), and `xc7k160tfbg484-3` (fastest
  installed silicon). To run the real part, install Zynq-7000 support via the
  Vivado installer and rerun — the scripts already take the part as an
  argument, so it is one command:
  `vivado -mode batch -source syn/vivado_ooc.tcl -tclargs xc7z020clg400-1 4.0`.
* The 250 MHz goal was not met (80.2 MHz on the -1 proxy, 185.3 MHz on the
  fastest installed part). Per spec §7 this is reported as-is; no issue rule,
  latency, or interface behavior was relaxed to improve frequency.
* Hold slack is slightly negative in OOC reports (see Results) — an artifact of
  unbuffered-clock modeling, not a design defect.
