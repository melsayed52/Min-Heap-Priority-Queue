# NOTES — hazard log and how each case is covered

Running log of every hazard/corner case discovered during design and debug,
and the test that covers it. Companion to ARCHITECTURE.md §9.

## Hazards designed-in from the paper (§III-C, §V-A)

| Case | Mechanism | Test coverage |
|---|---|---|
| Insert reads a node the op 1 cycle ahead writes at the use-edge | depth-2 write history (age-1 entry) | `t_hz_chases` desc/asc back-to-back inserts; random |
| Insert reads a node the op 2 cycles ahead wrote at the array-read edge | history age-2 entry | same |
| Delete children stale vs ops 2/3 cycles ahead | history on 4-wide lanes | `D-bubble-D chase`, drain tests, random |
| Delete 1 cycle after insert | insert aborted, its traveling value refills the root via the lastEntry bus; delete's level-2 read never sees the (suppressed) insert activity | `t_hz_abort_depths` gap sweep 0..28 idle cycles + multi-insert chains; random mixed streams |
| Delete 1 cycle after delete | banned via `ready_del` bubble; TB asserts the bubble is exactly one cycle | `t_ready_rules` |
| In-flight sift vs slot consumed by a newer delete (steal races H6–H8) | per-sift frozen bound + same-cycle clamp broadcast (`count_next`), plus write-snoop and same-cycle steal forward into the refill | `t_hz_drain_chains` (const keys, boundary drains), random delete-heavy |
| Insert landing the cycle a delete issues | landing insert still "live": kill suppresses its write, value stolen | `landing exactly at delete` sweep |
| m=0 delete chains at 2-cycle spacing | dual shadow (lastVal/lastVal2) + prefetch with retry + forward-on-arrival (`arr_covers_S`) | boundary drains at every level 4..14; sustained drain throughput phase (0.500 measured) |

## Bugs found during bring-up (all fixed, all now covered)

1. **Prefetch grant discarded on simultaneous new launch.**
   `g0_v <= pf_granted && !pf_launch` dropped the granted read whenever the
   next m=0 delete launched a new prefetch in the grant cycle — every
   2-cycle drain chain crossing a BRAM level boundary starved `lastVal`
   and `ready_del` stuck low (first seen at count=31 = level-5 boundary).
   Fix: grant and launch proceed independently (g0/g1 carry the granted
   slot; the pending register takes the new target).
   Covered by: `m=0 delete chains across level boundaries` + the TB's
   protocol assertion that `ready_del` is high whenever count>0 and no
   bubble (any recurrence is an instant test failure, not a silent stall).

2. **Combinational loop `ready_del -> kill -> insert-we -> steal scan ->
   refill_ok -> ready_del`** (found by yosys `check`, not by simulation).
   The steal-forward existence scan read the muxed per-level write bus,
   which includes insert write-enables gated by the abort kill.
   Fix: scan `del_v_r`/`del_n_r` registers instead — only a delete sift can
   write the slot a delete is consuming (an insert landing there would be
   the abort victim itself, handled by the m>=1 bypass branch), so the scan
   is semantically identical and register-sourced.

3. **TB**: reset-release race made the first ready check spurious
   (checker gated by `chk_en` now); boundary-chain test tried to fill to
   2^14+6 > capacity (capped).

4. **First P&R attempt: WNS −18.9 ns at 4 ns on -1 fabric.** The entire
   delete-issue decision was one combinational cone: live-insert flags →
   popcount → youngest priority mux (13×48b) → refill mux → refill_ok →
   ready_del → del_acc → per-stage bound clamps (serial 15-bit min) →
   compare/select trees → write data → shadow write-match scans → shadow/
   pipeline registers. 35 logic levels, 23 ns. Fixed by retiming (no change
   to interface, issue rules, or latencies):
   * refill pre-registered one cycle ahead (`refill_r`, sources A/B/C, see
     ARCHITECTURE.md §5), leaving only the shallow register-compare
     `steal_now` in the issue cycle;
   * youngest one-hot and S registered (`young_r`, `S_r`), popcount removed;
   * shadow snooping moved to a registered write record (`gwr`, one cycle
     late; staleness cases closed by construction — the interior-S writers
     require m ≥ 1 and lastVal is only consumed after m returns to 0, ≥1
     cycle later);
   * dual shadow extended to triple (`lastVal3`) so prefetch arrivals enter
     via registers only, removing BRAM dout2 from the refill cone;
   * per-stage occupancy clamp decomposed into parallel compares.
   Full regression re-run after the rework (same testbench, same checks).

5. **Central `vpipe`/`cwr` mirrors — a retiming pass that did not pay off.**
   Diagnosis after pass 5: the `refill_r` gather collected 48-bit buses
   (`del_w_r`, `ins_w_r`) from all 14 stage register files, which placement
   spreads over the die, so the cone was ~75 % routing. Fix: mirror those
   values centrally (`vpipe[j] == del_w_r[j+1]` since V is invariant down a
   sift; `cwr[j] == ins_w_r[j]` by construction, same source and edge) and
   point `sb_data`, `le_val`, `land_data_c` at the mirrors, leaving only 1-bit
   hit signals crossing the die.
   *Result: bit-exact (identical sim output, identical throughput) and the
   worst path did move off the 48-bit gather — but WNS improved by only
   0.078 ns on a100t-1 (−8.216 → −8.138) and got 0.050 ns worse on k160t-3
   (−1.888 → −1.938, i.e. noise).* The reason is in ARCHITECTURE.md §10: a
   second cone (`ins_k_r` → BRAM write-enable) sits within 0.07 ns of the
   first, so emptying one cone just exposes the next. Kept because it is free
   and strictly reduces long-bus count, but it is **not** a timing fix.
   Lesson: before retiming a cone, check the *second*-worst path — if it is
   within noise of the worst, single-cone work cannot help.

   Two defects in that edit worth recording: the mirror block referenced
   `refill`, which is declared later in the file, so `pheap.v` did not
   elaborate at all (the code had never been compiled); and it reused the
   loop integer `wk` already driven by the `gwr` process, which yosys reported
   as 32 multiple-driver warnings. Both fixed (`nx_del_w[1]` is the same net
   as `refill` and is declared early; the process now owns a private `wm`).

6. **`count_next` candidate precompute — logic won, routing ate it.**
   Reading the routed worst path showed ~4.4 ns of the 12 ns cone was just
   *forming* `count_next` (a 15-bit ±1 carry chain, 4 CARRY4) plus its
   fanout-42 broadcast, before any comparison. Fix: since ins_acc/del_acc are
   mutually exclusive, `count_next ∈ {count_r−1, count_r, count_r+1}`;
   pre-register the two shifted candidates (`candm1_r`/`candp1_r`; `count_r`
   itself is a register) and rewrite the refill B/P/stage-1 compares to run
   register-to-register against all three, with ins_acc/del_acc steering a late
   1-bit select. Bit-exact (quick + yosys + 6-seed all PASS).
   *Result: logic depth 16→13 levels, 6→4 CARRY4, logic 4.74→3.09 ns — but WNS
   did not move (a100t-1 −8.138 → −8.169, noise) because the route fraction
   rose 60 %→74 %: the freed logic time was absorbed by routing, and the extra
   comparators spread the gather slightly wider.* Kept (lower logic floor,
   harmless). This is the **second** proof that the refill cone is
   routing-bound, not logic-bound.

7. **Floorplanning cannot fix it (attempted, rejected).** A pblock compacting
   the core to half the die (`CLOCKREGION_X0Y0:X0Y3`) made WNS *worse*
   (−8.169 → −8.921): forcing the 40 BRAM tiles into 2 columns instead of 4
   raises congestion. The deeper reason no placement helps: the refill value
   is a **1-cycle 14→1 reduction** whose sources are registers sitting next to
   their BRAMs, and every pipeline level owns banks in all 4 BRAM columns, so
   the sources are *necessarily* spread across the full die width. One
   destination FF cannot be near 14 die-spread sources. The spread is logical,
   not placement sloppiness. `syn/vivado_ooc_fp.tcl` kept for the record; the
   shipping flow does not use it.

**Conclusion of the timing campaign (passes 5–7):** logic retiming and
placement are both exhausted; the only remaining lever is architectural — give
the 14→1 refill gather its own pipeline stage so no single cycle crosses the
die (register the per-stage hit bits mid-path). See docs/PLUS1_STAGE.md. The
verified pre-rework RTL is preserved at `rtl/pheap_baseline_verified.v`.

## Prefetch arbitration liveness (why retries suffice)

Read-port priority per level: delete grandchildren > insert path > prefetch.
For a max-rate m=0 delete chain (deletes every 2 cycles), the two deletes
adjacent to a prefetch window block at most the two same-parity edges of
{launch+1, launch+2}, and any insert old enough to occupy the remaining edge
would have to be live — but m=0 at the launching delete means all older
inserts have landed, and inserts issued after the launch reach that level's
read port only >= 3 cycles later. Hence a prefetch is granted at latest at
launch+2, arriving at launch+4 with the `arr_covers_S` forward feeding the
refill in that same cycle. The TB's ready_del assertion plus the measured
0.500 drain rate confirm this empirically across all level boundaries.

## Known limitations / deviations

* Capacity 16383 (= 2^14-1 complete tree), not "16384".
* Layout: stage logic is in generate blocks inside `pheap.v` rather than
  separate `pheap_stage*.v` files — the cross-level wiring (read-address
  from L-3's compare, 4-wide data to L-1, history export, kill/snoop/clamp
  broadcasts) made explicit per-level port marshaling strictly more
  error-prone. `ram_dp.v` is the only submodule.
* TB reference limits each 16-bit ID to at most 8 simultaneous live keys
  (TB issues rolling IDs; the DUT has no such restriction).
