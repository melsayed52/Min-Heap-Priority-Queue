# HANDOFF PROMPT — Pipelined Binary Min-Heap Priority Queue (Hardware, Verilog-2001)

You are picking up a nearly-finished hardware project at `C:\Claude\Code\PQ`. Read
this whole document, then `docs/ARCHITECTURE.md` and `docs/NOTES.md`, before
touching RTL. The original specification (issue rules, throughput targets,
verification plan, honest-reporting rules) is at the top of the previous session;
its key points are restated here.

## What this project is

A synthesizable pipelined binary min-heap priority queue after Ioannou &
Katevenis, "Pipelined Heap (Priority Queue) Management for Advanced Scheduling
in High-Speed Networks," IEEE/ACM ToN 15(2) 2007 — their "version (ii)":
one pipeline stage per heap level, 2-port 4-wide memories, ops ripple one
level per cycle. The paper PDF is in `C:\Users\melsa\Downloads\Pipelined_Heap_...(1).pdf`;
extracted text per page in the session scratchpad (re-extract with pypdf if needed).

* 14 levels, capacity 16383 (=2^14−1; the spec said "16K/16384" — documented deviation).
* Entry = 32-bit unsigned key (min-heap) + 16-bit ID = 48 bits. `KEY_W/ID_W/LEVELS` parameterized.
* Pure Verilog-2001, no SystemVerilog, no vendor primitives. Two RTL files only.
* Throughput (HARD SPEC, verified): 1 insert/cycle sustained; 1 delete per 2 cycles;
  insert legal the cycle after anything; delete legal the cycle after an insert
  (that insert is aborted per the paper — its traveling value becomes the root refill);
  delete-after-delete needs one intervening cycle (`ready_del` bubble).
* Interface (in `rtl/pheap.v`): op (00 NOP/01 INSERT/10 DELETE_MIN), ins_key/ins_id,
  ready_ins/ready_del, del_valid/del_key/del_id (registered, exactly 1 cycle after
  accept), count/full/empty. Issuing while !ready is a TB error, not tolerated.
* Timing goal: 250 MHz (4.0 ns) post-P&R OOC. Target part per spec: xc7z020clg400-1.
  **This machine's Vivado 2025.1 (C:\Xilinx\2025.1, use `C:\Xilinx\2025.1\Vivado\bin\vivado.bat`)
  has NO Zynq-7000 device support installed** (only Artix-7/Kintex-7/Virtex-7/Spartan;
  no UltraScale+, no usable Versal; adding devices needs an AMD-account download the
  agent cannot do — tell the user). Proxy used so far: **xc7a100tcsg324-1** (the
  7z020's PL is Artix-7 fabric, same -1 grade → representative), plus
  **xc7k160tfbg484-3** as the fastest installed silicon. The spec's §7 explicitly
  allows honest reporting of achieved Fmax + a faster-part demonstration if 250 MHz
  won't close on the -1 part; never trade away the issue rates for frequency.

## Repository layout & how to run

```
rtl/pheap.v        top + ALL stage logic in generate blocks (documented deviation
                   from the suggested per-stage files; ram_dp.v is the only submodule)
rtl/ram_dp.v       inferable SDP RAM, sync read, 2-flop output (dout_r -> dout2), read-first
tb/tb_pheap.v      self-checking TB (plain Verilog): reference = software binary heap
                   (keys) + per-ID key table (multiset-correct for duplicate keys);
                   directed smoke/hazard suites; randomized phases; throughput
                   measurement with hard assertions; protocol assertions that
                   ready_del/ready_ins are high whenever the spec requires
                   (any pf/shadow stall = instant test failure, not a silent slowdown)
sim/               tb.vvp (current build), run_s*.log (final regression logs),
                   Makefile, run.ps1
syn/               vivado_ooc.tcl  (usage: -tclargs <part> [<period_ns>]; writes
                   syn/out_<part>_p<period>/ with post_route_timing/util/paths reports,
                   prints RESULT_WNS/RESULT_WHS; opt_design runs -retarget -propconst
                   -sweep explicitly to keep bram_power_opt from gating BRAM read
                   enables — do not revert that),
                   vivado_ooc_aggr.tcl (aggressive directives, fixed 4.0 ns),
                   timing.xdc, yosys_check.ys, parts_list.txt (all installed parts)
docs/ARCHITECTURE.md  full microarchitecture: pipeline schedules, lastEntry/shadow
                   scheme, occupancy bounds/clamping, depth-2 write-history bypasses,
                   port-conflict audit, hazard table H1..H14
docs/NOTES.md      hazard->test map, every bug found (incl. the timing-rework story),
                   prefetch liveness argument, known limitations
SUMMARY.md         SKELETON ONLY — "Results" section still says RESULTS PENDING;
                   must be finished (see step 5 below)
```

Simulation (iverilog 14.0 via OSS CAD Suite at `C:\Claude\Code\PQ\tools_dl\oss-cad-suite`):
```
cmd /c "call C:\Claude\Code\PQ\tools_dl\oss-cad-suite\environment.bat && cd /d C:\Claude\Code\PQ && iverilog -g2005 -o sim\tb.vvp -s tb_pheap tb\tb_pheap.v rtl\pheap.v rtl\ram_dp.v && vvp sim\tb.vvp +quick +seed=1"
```
`+quick` ≈ 207k ops / ~2 min. Full (no +quick) ≈ 1.05M ops / ~30-60 min. Yosys lint:
`yosys -s syn\yosys_check.ys` (must stay free of "logic loop" and inferred latches —
it caught a real ready_del combinational loop once).
Vivado: `C:\Xilinx\2025.1\Vivado\bin\vivado.bat -mode batch -source syn\vivado_ooc.tcl -nojournal -log syn\x.log -tclargs xc7k160tfbg484-3 4.000`
(~15 min; run in background; grep RESULT_WNS).

## Verification status: DONE and PASSING (do not regress this)

* Directed suites: smoke (fill/drain asc/desc/dup/extremes, fill-to-full 16383,
  empty/full ready rejection), ready-rule checks (bubble exactly 1 cycle), hazard
  suites: I-I chases, D-bubble-D chases (paper Fig. 6), insert-abort at every depth
  (gap sweep 0..28 + multi-insert chains), m=0 delete chains across every level
  boundary (lastVal prefetch stress), constant-key tie storms, landing-at-delete sweeps.
* Randomized: 4 weighted phases (insert-heavy/balanced/delete-heavy/narrow-key) at
  max legal rate driven off ready_*.
* **Final regression: 6 seeds (101..606) × 1,050,532 ops, 0 errors** (logs in
  sim/run_s101.log … run_s606.log, `RESULT: PASS` at the end of each).
* Measured throughput (asserted in TB): insert saturation 1.000 ops/cycle;
  delete/insert alternation 1.000 ops/cycle; pure delete drain 0.500025 ops/cycle.
* The regressions were run on RTL functionally identical to the current
  `rtl/pheap.v` — see "IN-PROGRESS EDIT" below (the only uncommitted change adds
  two mirror register files that are updated but not yet consumed).

## Microarchitecture summary (details in docs/ARCHITECTURE.md)

* Levels 1–4 in flip-flops (comb read at compare cycle → no bypass needed there);
  levels 5–14 = four ram_dp banks each (4-wide read word = the paper's grandchildren
  read, single-entry write), depth-2 per-level write history = the paper's "local
  bypasses from the two stages below".
* Insert path precomputed from T=count+1 (MSB steers); compare at level L in cycle
  L−1; write at end of compare cycle. Delete: refill from lastEntry, min-of-3 per
  level, read address for level L+3 driven combinationally by the level-L compare's
  1 direction bit (this is why registered-output BRAM still sustains 1 level/cycle).
* lastEntry machinery (the hard 20%): live inserts have consecutive targets ending
  at count; youngest is aborted by a delete (kill one-hot young_r, registered).
  Settled-last S tracked as register S_r; triple shadow lastVal/2/3 (slots S, S−1,
  S−2) + BRAM prefetch with retry for slot S−3 refills; snooping via a one-cycle-
  delayed global write record (gwr_*); per-sift occupancy bound frozen at issue and
  clamped same-cycle by newer deletes (occ compares decomposed into parallel
  register-vs-register candidate compares).
* Everything a delete consumes at issue is pre-registered: refill_vld_r (validity,
  keeps ready_del register-shallow) and refill_r (data from sources P/B/C:
  sift-entering-consumed-slot prediction, sift-settled-write, lastVal-chain);
  source A (youngest live insert's traveling value) is muxed at issue from
  young_r × ins_w_r. Mutual-exclusivity proofs for the sources are in NOTES.md.
  The shadow next-state is computed as three parallel banks (up/hold/down vs
  five candidate slots S_r+1..S_r−3) with s_up/s_down only steering final 3:1 muxes.

## Timing status (the one open engineering problem)

Journey at 4.0 ns on xc7a100t-1: −18.9 → −13.5 → −10.9 → −9.2 → **−8.2** WNS through
five retiming passes (all described in NOTES.md; every pass re-verified by quick sim,
final one by the full 6-seed regression). Current numbers (final RTL):

| Run | Part | Period | WNS | Notes |
|---|---|---|---|---|
| default flow | xc7a100tcsg324-1 | 4.0 | −8.216 | worst: rw1q/hist → stage compare → steal_pred/sb_data → refill_r |
| default flow | xc7a100tcsg324-1 | 8.0 | −3.833 | same cone; **logic only 2.9 ns, routing 8.9 ns (75%)** |
| default flow | xc7k160tfbg484-3 | 4.0 | −1.888 | fastest installed silicon |
| aggressive   | xc7k160tfbg484-3 | 4.0 | **−1.426** | syn/out_aggr_xc7k160tfbg484-3/ |
| utilization  | — | — | — | ~13.9k LUT, ~6.9k FF, BRAM per util rpt (a100 21.6% LUT — not congested) |

Diagnosis of the remaining gap: the refill_r gather cone collects 48-bit buses
(del_w_r, ins_w_r via nx_ins_w, history-fixed compare outputs) from pipeline
registers that placement spreads across all 14 level columns → route-dominated.
The intrinsic logic is ~3 ns.

## IN-PROGRESS EDIT (finish this first)

`rtl/pheap.v` already contains two central mirror register files (added, updated
every cycle, **but consumers not yet re-pointed — currently dead logic**):
* `vpipe[j]` = carried V of the delete issued j cycles ago (V is invariant down a
  sift, so `vpipe[j-1]` at time t == `del_w_r[j]` of the op comparing at stage j);
  fed by `vpipe[1] <= refill`.
* `cwr[j]` = exact mirror of `ins_w_r[j]` (fed from `nx_ins_w[j-1]`, same edge).

Remaining steps of the routing fix (all functionally equivalent — verify with quick
sim after; expected bit-identical results):
1. In the `sb_data` scan (P/B sources), replace `del_w_r[wj*ENT +: ENT]` with
   `vpipe[(wj-1)*ENT +: ENT]` (both occurrences: the B arm and the P arm; leave the
   stage-1 handoff arm using `nx_del_w[1*ENT +: ENT]`).
2. In the `le_val` loop, replace `ins_w_r[sj*ENT +: ENT]` with `cwr[sj*ENT +: ENT]`.
3. In the `land_data_c` loop, replace `ins_w_r[lj*ENT +: ENT]` with `cwr[lj*ENT +: ENT]`.
This leaves only 1-bit hit signals traveling from the stages to the central refill
logic; the 48-bit muxes then read local flip-flops (placer pulls vpipe/cwr next to
their only consumers). Expect a1 WNS to improve substantially; k3 likely lands
within ~1 ns of closing.

## Workflow from here

1. Finish the in-progress edit (above). Rebuild + `+quick +seed=1` sim → must PASS
   with identical throughput lines. Run `yosys -s syn\yosys_check.ys` → no loops/latches.
2. Rerun timing: a1@4.0, k3@4.0 (default), k3@4.0 aggressive
   (`vivado_ooc_aggr.tcl`), then honest-Fmax probes at informed periods
   (pick period ≈ 4.0 + |WNS| − 0.2 and iterate once or twice to find where WNS ≥ 0;
   e.g., a1 at 6.0–7.0, k3 at 4.2–5.0). Also one xc7a100tcsg324-2 run at its
   achievable period (the -2 Artix ≈ a Zynq-7020-2's fabric, a realistic user option).
   Run Vivado in background (`run_in_background`), ~15 min each, ≤2 concurrent.
3. If k3 gets within ~0.5 ns at 4.0: try `route_design -directive AggressiveExplore`
   reruns / `phys_opt_design` iterations before concluding. If a1/4.0 still fails
   (expected): per spec §7 this must be reported honestly — do NOT add stalls or
   change issue rules. Next-level structural options (only if pursuing further):
   the "+1 stage-0 shift" (give the whole issue cycle its own pipeline stage; needs
   the delete result to become min(root, pending-stage-0-insert) and a full hazard
   re-audit — sketched at the end of the session, ~day of work), or floorplanning
   (pblocks clustering levels around the shadow logic).
4. If ANY functional RTL change is made after this point, rerun the full 6-seed
   regression (background, low priority, ~30–60 min each:
   `vvp sim\tb.vvp +seed=101 > sim\run_s101.log` etc. for 101,202,303,404,505,606).
   The current PASS logs correspond to the current function — keep them if only
   the mirror re-pointing (equivalent) changes, but a paranoid full rerun is cheap
   overnight.
5. Finish `SUMMARY.md` "Results": final regression table (6 seeds × 1,050,532 ops,
   0 errors), measured throughput (1.000 / 1.000 / 0.500 ops per cycle), the timing
   table (all parts × periods, WNS, achieved Fmax = 1000/(period−WNS_at_that_period)
   only for runs where WNS≥0; otherwise state the closing period found), utilization
   (LUT/FF/BRAM from post_route_util.rpt), and the deviations list (capacity 16383;
   flat stage layout; Artix/Kintex proxy parts because Zynq-7000 device files are
   not installed — the user must add Zynq-7000 support via the Vivado installer with
   their AMD account to run the literal xc7z020clg400-1 flow; the tcl already takes
   the part as an argument, so it is a one-command rerun afterwards).
   Also update ARCHITECTURE.md §5/NOTES.md if the mirror change ships (one paragraph:
   "central vpipe/cwr mirrors decouple refill gather routing").
6. Deliverable check per the original spec: RTL complete ✓, regressions vs reference
   model ✓ (1M+ ops × 6 seeds), throughput demonstrated & printed ✓, synthesis+P&R
   run with honest timing report (finish step 2/5), SUMMARY.md (finish step 5).

## Known traps (learned the hard way — do not rediscover)

* Never let anything combinational feed `ready_del` from the per-stage write buses
  or compare cones (past bug: ready_del→kill→insert-we→steal-scan→refill_ok loop;
  yosys `check` catches it, simulation does not).
* `opt_design` default includes bram_power_opt which gates BRAM read enables with
  consumer-valid logic — keep the explicit `-retarget -propconst -sweep`.
* A prefetch grant and a new prefetch launch can coincide (max-rate drains at level
  boundaries); the granted read must keep flowing through g0/g1 regardless
  (past bug: count froze at 31 with ready_del stuck low).
* The TB drives ops only when ready, AND asserts ready must be high whenever the
  spec demands it — that assertion is the throughput spec's watchdog; treat any
  fire as a real bug.
* PowerShell 5.1 here: no `&&`, BOM-free files needed for Vivado tcl (use the Write
  tool or [System.IO.File]::WriteAllText), iverilog/yosys need
  `call ...\oss-cad-suite\environment.bat` first, and long `Start-Sleep` is blocked —
  use background tasks + monitors.
