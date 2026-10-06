# +1 Pipeline Stage — design for splitting the refill gather

**Status: DESIGN IN PROGRESS. Not yet implemented. The verified baseline is
`rtl/pheap_baseline_verified.v`; this document plans a from-baseline rework.**

## Goal

Break the timing wall. Every failing path is 74–76 % routing because the delete
refill value is a **one-cycle 14→1 reduction** whose sources are registers
spread across the whole BRAM array (proven in NOTES.md passes 5–7: neither
retiming nor floorplanning helps). The only structural fix is to insert a
register into that reduction so no single cycle crosses the die.

Target: turn the current worst path

```
rw1q(t) → history fwd → child compare(t) → b_dir(t) → nx_del_n(t)
        → == count_next → steal_pred(t) → gather → refill_r(t)      (~12 ns)
```

into two register-bounded halves, each ~5–6 ns.

## The one idea

The steal source (P) is the long pole: it depends on `b_dir[wj](t)`, this
cycle's compare result, which chases the BRAM child read. But
`nx_del_n[wj](t)` (the node the sift moves to) **is registered next cycle** as
`del_n_r[wj+1](t+1)`. So if the delete's refill is consumed **one cycle later**
than today, the same "does a sift sit on the consumed slot" question can be
answered from the *registered* `del_n_r` instead of the combinational
`b_dir` — the compare→b_dir→steal path vanishes from the refill cone.

Concretely: add one pipeline stage ("stage 0", the *accept* stage) ahead of the
current level-1 issue, applied to **both** inserts and deletes uniformly.
Because both op types shift by one cycle, **op-vs-op relative timing is
unchanged**, so the hazard mechanisms that are about two ops racing each other
(write history, steal races, insert-abort, prefetch arbitration) keep their
existing derivations. Only the relationship between a delete and *its own*
refill/result changes, plus one new window (an op sitting in stage 0 that has
not yet reached the root).

## New pipeline schedule (cycle numbers relative to accept)

| Cycle | Today | With +1 stage |
|---|---|---|
| 0 (accept) | level-1 compare, root write, result capture, count update | **register op into stage 0** (op, key/id, and the frozen bound/target); update count; capture the delete **result** = min(root, stage-0 pending insert) → `del_valid` at cycle 1 (latency preserved) |
| 1 | level-2 compare | **level-1 compare**, root write, refill consumed here |
| 2 | level-3 compare | level-2 compare |
| … | | (everything shifted down one cycle) |

Delete result latency stays **1 cycle**: the result is still captured at accept
(cycle 0), only the sift/refill moves to cycle 1.

### Why `min(root, stage-0 insert)`

An insert accepted at cycle 0 does not write the root until cycle 1. A delete
accepted at cycle 0 (right after that insert, the legal back-to-back case)
captures the result at cycle 0 — when the root register does not yet reflect
the pending insert. If the pending insert's key is smaller than the current
root, the true min is the insert's key. Hence result = min(root, pending
stage-0 insert key). (Today the insert's level-1 compare at its own cycle 0
fixes the root before any later delete reads it, so no such window exists.)

## Re-derivation of each mechanism

Legend: **unchanged** = relative op timing preserved ⇒ existing argument holds;
**shift** = same argument, indices shifted by one cycle; **new** = needs fresh
logic/proof.

1. **Refill sources A/B/C.**
   - B (sift settling on the consumed slot) and the old P (steal_pred) **merge**:
     with the deferred consumption, both become "registered `del_n_r[wj]`
     equals the consumed slot", evaluated the cycle the sift is resident — i.e.
     the B form only, now register-sourced. **The combinational P path is
     deleted.** *(This is the whole point.)*
   - A (youngest live insert) — unchanged in role; the abort still kills it.
     Needs the stage-0 insert included in "youngest live" (new earliest slot).
   - C (lastVal shadow) — **shift** by one cycle (see §S_r below).
   - `steal_now` same-cycle compare — removed (folded into B).

2. **`S_r` / settled-last tracking.** Event-based ±1 (landing +1, m=0 delete
   −1). Events now fire one cycle later (landing at cycle k instead of k−1;
   delete decrement at cycle 1 instead of 0). **shift**; the +1/−1 amounts are
   unchanged. Reset value unchanged.

3. **Triple shadow `lastVal/2/3`.** Tracks slots S, S−1, S−2. The shift-up
   (landing) / hold / shift-down (m=0 delete) next-state banks are driven by the
   same events, one cycle later. **shift.** The three-deep margin for prefetch
   is unchanged (still two delete-periods).

4. **`young_r` one-hot (youngest live insert).** Priority-encoded one cycle
   ahead today. With stage 0, the youngest live insert may be in stage 0; extend
   the encode to include it. **new (small):** add stage-0 to the priority mux;
   its traveling value is the raw `Wins`.

5. **`gwr` write-snoop (one cycle late).** Snoops committed writes against
   shadow slots. Writes now commit one cycle later; the shadow slots update one
   cycle later; the one-cycle lag is preserved. **shift.** The staleness
   case-analysis (interior-S writers require m≥1, lastVal consumed only at m=0)
   is about op-vs-op spacing ⇒ **unchanged.**

6. **Depth-2 write history (local bypass).** Covers ops issued 1 and 2 cycles
   before a consumer. Both producer and consumer shift by one cycle ⇒ relative
   spacing unchanged ⇒ **unchanged, depth-2 still exact.** (Key relief: uniform
   +1 on both op types keeps this proof intact.)

7. **Occupancy bound freeze + same-cycle clamp (H6/H7/H8).** Freeze at issue,
   clamp broadcast the cycle a newer delete issues. Both deletes shift by one
   cycle ⇒ the clamp is still "same cycle as the newer delete's (shifted)
   issue". **shift.** Re-verify the clamp still lands before any in-flight sift
   pulls up the stolen slot — should hold since sift also shifted.

8. **Prefetch launch/grant/arrival + liveness.** Read-port priority and the
   2-cycle drain cadence are op-relative ⇒ **unchanged**; absolute launch/grant
   cycles **shift** by one. Re-check the `arr_covers_S` forward lands in the
   (shifted) consume cycle.

## New hazards introduced by stage 0 (the genuinely new work)

* **H15 — delete result vs pending stage-0 insert.** Covered by
  `min(root, stage0_ins_key)` in the result capture. Test: insert then delete
  back-to-back with the insert key both smaller and larger than root, at every
  count.
* **H16 — delete consuming a slot a stage-0 insert just created.** The stage-0
  insert's target is `count` at its accept; a delete one cycle later freezes its
  bound to exclude it (same serialization rule, one cycle later). Re-audit.
* **H17 — two ops resident in stage 0 across the pipeline seam.** With one op
  accepted per cycle, stage 0 holds exactly one op; the level-1 stage holds the
  previous op. Confirm no structural double-write at level 1.

## ready_del / ready_ins

Must not depend on the deleted long path. `ready_del` still keyed on
`refill_vld` (registered) + bubble + count. With refill now register-gathered a
cycle deeper, `refill_vld` is strictly shallower — good. `ready_ins = ~full`
unchanged. The bubble rule (one cycle after a delete) is op-relative ⇒
unchanged.

## Verification plan (gates — do not skip)

1. Quick sim (`+quick +seed=1`) after each incremental step; must PASS with the
   **same** throughput lines (1.000 / 1.000 / 0.500) — latency and issue rates
   are unchanged by construction, so any deviation is a bug.
2. `yosys -s syn/yosys_check.ys` — no logic loops / latches.
3. Full 6-seed regression before trusting timing.
4. Then a1@4 / k3@4 timing; expect the worst path to leave the
   `rw1q→…→refill` cone. Iterate periods for closure.

## Implementation order (each gated on quick sim)

1. Add stage-0 registers for the **insert** path only; move insert level-1
   compare to cycle 1; add `min(root, stage0_ins)` to the delete result. Verify
   inserts + delete-after-insert.
2. Add stage-0 for the **delete** path; move refill consumption to cycle 1;
   switch steal detection to registered `del_n_r`. Verify delete chains.
3. Shift `S_r`, shadows, `gwr`, prefetch by one cycle. Verify drains/boundaries.
4. Re-audit H6/H7/H8 clamp timing; full regression.

## Risk / fallback

High risk (redesign of the control plane). At any failed gate that cannot be
resolved quickly, revert to `rtl/pheap_baseline_verified.v` — the shipped
deliverable (verified, honest Fmax) is already complete and independent of this
effort.
