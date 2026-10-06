# Pipelined Binary Min-Heap Priority Queue — Microarchitecture

Implements Ioannou & Katevenis, *"Pipelined Heap (Priority Queue) Management for
Advanced Scheduling in High-Speed Networks"*, IEEE/ACM ToN 15(2), 2007 —
their **version (ii)**: 2-port 4-wide memories, one-stage-per-cycle ripple,
local bypasses only, delete-after-delete requires one intervening cycle.

## 1. Parameters and capacity

| Parameter | Value | Notes |
|---|---|---|
| `LEVELS` | 14 | level 1 = root (1 node) … level 14 (8192 nodes) |
| `KEY_W`  | 32 | unsigned, min-heap order; plain compare (no wrap-around per spec) |
| `ID_W`   | 16 | payload, never compared |
| Capacity | **16383** = 2^14 − 1 | a complete 14-level binary tree has 2^14−1 nodes; "16K" in the spec is nominal. `count` is 15 bits, 0..16383. |

Node indexing: root = global index 1; node *i* has children *2i, 2i+1*.
Level *L* holds indices 2^(L−1) .. 2^L−1; local address = index − 2^(L−1)
(low L−1 bits of the index).

## 2. Storage per level

| Levels | Storage | Read behavior |
|---|---|---|
| 1 | single register (+ result/count/shadow logic in stage 1) | combinational |
| 2–4 | flip-flop arrays (2/4/8 entries) | **combinational read at compare cycle** → no forwarding needed at these levels |
| 5–14 | 4 banks of inferred simple-dual-port BRAM, each `2^(L-3) × 48b`, common read address, per-bank write enable | synchronous, **2-edge latency** (`addr → dout_r → dout2`), registered output for timing |

4-wide read: the four children of the node pair {2a, 2a+1} live at indices
4a..4a+3 — one aligned word. Word (group) address at level L = local address of
node *a* at level L−2. Bank select = low 2 bits of local address.

Each BRAM level also keeps a **write-history of depth 2** (`{addr, data, valid}` ×2,
shifting every cycle): all consumers of read data check the history and take the
newer value on address match. This is the paper's "local bypasses from the two
stages below" in uniform form (see §6).

## 3. Pipeline schedule

One op accepted per cycle at stage 1. Ops ripple down one level per cycle.
"Cycle *c*" below is relative to issue (op accepted during cycle 0).
All writes are synchronous, committing at the **end** of the stated cycle.

### 3.1 INSERT (issued cycle 0, target slot T = count+1, target level k = MSB(T))

The path is fully determined at issue: the node on the path at level L is
`T >> (k−L)`.

| Cycle | Action |
|---|---|
| L−3 | (BRAM levels only) present read address of level L (path node's group; static) — clocked into BRAM at end of cycle |
| L−2 | BRAM array access (`dout_r` loads at end of cycle) |
| L−1 | `dout2` loads at end of cycle (L≥5). *(register levels: no prefetch, read combinationally in cycle L−1)* |
| **L−1** | **Compare at level L**: traveling value W vs resident R (after history-forwarding fixup). If L == k: land, write W. Else write min(W,R) at end of cycle L−1; max continues down. Tie: resident stays. |

Insert writes level L at end of cycle L−1 (same offset as delete — see §7 for
why this creates no write-port conflict). An insert is **live** from issue until
its landing write commits (end of cycle k−1); a landing insert killed in its
landing cycle commits nothing.

### 3.2 DELETE-MIN (issued cycle 0)

Cycle 0: root register (valid because any previous op fixed the root by the end
of its own issue cycle) is captured as the result → `del_key/del_id` registered,
`del_valid` pulses in cycle 1. Refill value V = lastEntry (§5). The sift then
ripples down. `n_L` = node at level L being (re)written; `n_1` = 1.

| Cycle | Action |
|---|---|
| **L−1** | **Compare at level L**: min3(V, c0, c1) where c0/c1 = children of n_L at level L+1, selected 2-of-4 from level L+1 read data (or read combinationally for child levels ≤4), after history fixup and occupancy masking (§4). min3 is written to level L node n_L at end of cycle L−1. If a child was min: that child's slot becomes n_{L+1}, op continues with same V. If V min or no occupied children: V written, sift terminates. |
| L−1 (same cycle) | Compare result bit b gives n_{L+1} = 2·n_L + b, which **combinationally** drives the read address of level L+3's BRAM (group = local(n_{L+1})): clocked end of L−1, `dout_r` end of L, `dout2` end of L+1, consumed by compare at level L+2 in cycle L+1. ✓ one stage/cycle sustained with registered BRAM outputs. |

Deriving the read timing: compare at L (cycle L−1) consumes level L+1 data ⇒
`dout2` loaded end of L−2 ⇒ `dout_r` end of L−3 ⇒ raddr presented during L−3,
driven by compare at level L−2 in that same cycle. The address is just
`{local(n_{L-2}), b}` — one fresh bit appended to registered bits, keeping the
compare→address path short.

Boundary: compare at level 4 (cycle 3) needs level-5 data ⇒ level-5 raddr
during cycle 1, from compare at level 2. Compares at levels 1–3 read FF levels
2–4 combinationally.

### 3.3 Result latency

`del_valid`, `del_key`, `del_id` are registered once: valid in the cycle after
the delete is accepted. Deterministic latency = **1 cycle**.

## 4. Occupancy (empty-slot) rules

No valid bits in RAM. A child slot index X is **occupied** for a delete D's
compare iff `X ≤ bound_D_eff`:

* At issue, D freezes `bound_D = (count at issue) − 1` (its own consumption).
  Slots created by inserts issued *after* D are thereby excluded (serialized
  semantics: newer inserts logically follow D; their memory content is garbage
  until landing).
* Every later delete broadcast-clamps all in-flight deletes:
  `bound_D ← min(bound_D, count_after_newer_delete)`. This exclusion must act
  **in the same cycle** the newer delete issues (`bound_D_eff = min(bound_reg,
  issuing_delete ? count_next : ∞)`), otherwise an in-flight sift could pull up
  the very slot the new delete is stealing (hazard H7).

Inserts need no occupancy checks: a live insert's path nodes are strict
ancestors of its target and always occupied and never stolen (a delete that
would consume slot ≤ T aborts the insert first — targets of live inserts are
consecutive ending at `count`).

## 5. lastEntry: refill value for deletes (retimed for 4 ns)

Live inserts have consecutive targets `[count−m+1 .. count]` (m = number of
live inserts): a new insert appends; a delete aborts the youngest; the oldest
lands first. The *settled last slot* is therefore `S = count − m`, kept as a
**register** `S_r` with an event-based update (+1 landing commit, −1 m=0
delete). The youngest live insert is a **registered one-hot** `young_r`
(priority-encoded one cycle ahead from the stages' next-state flags).

The refill value a delete consumes at issue is **pre-registered**: during
every cycle t the design computes what a delete issued at t+1 (consuming slot
`count_next`) would need, and registers it as `refill_r`/`refill_vld_r`.
Priority, newest source first:

* **A — youngest live insert at t+1** (`nx_ins_v/nx_ins_w` of the stages):
  the abort bypass. The delete at t+1 kills that insert (one-hot `young_r`),
  suppressing its compare/write in the issue cycle and everything after; its
  earlier level writes are consistent partial state.
* **B — a sift writing the consumed slot at end of t**: detected from
  `del_v_r/del_n_r` registers (`node == count_next`); the written value is
  necessarily the sift's carried V (`del_w_r`) because the last slot's
  children are always empty.
* **C — the lastVal shadow chain's next state** (m=0 settled value).

The only same-cycle source at t+1 is **steal_now** (H7 late case: a sift
sitting on the consumed slot in the issue cycle itself), which is a shallow
register compare (`del_n_r == count_r`, data `del_w_r`).
`ready_del = count≠0 && !bubble && (count==1 || refill_vld_r || steal_now)`.

**Triple shadow** `lastVal/lastVal2/lastVal3` = slots S, S−1, S−2:

* Landing (write commits end of this cycle): shift up, data taken directly
  from the lander's registers (nothing else ever writes a live target first).
* m=0 delete: shift down; `lastVal3`'s new slot S−3+... is filled by a
  combinational FF-level read (levels ≤4) or a **BRAM prefetch** with retries
  (read-port priority: delete grandchildren > insert path > prefetch).
  Three-deep shadows give the prefetch two full delete-periods of margin, so
  prefetch data enters the shadows **through registers only** (no
  combinational forward into the refill path).
* **Write snooping is one cycle late by design**: a registered copy of every
  level's write (`gwr_*`) is matched against the shadow slots. The one-cycle
  lag is covered case-by-case: sift-into-consumed-slot forwards through B or
  steal_now; landings forward directly; any other writer of a shadow slot is
  only consumed ≥2 cycles later (interior-S writes require m ≥ 1, and lastVal
  is not consumed until m returns to 0 — see NOTES.md).

**count == 1 delete**: no refill; root becomes empty. **Insert when empty**:
lands at root immediately (counts as a landing for S_r).

**Central mirrors (`vpipe`/`cwr`)**: the refill gather used to read the 48-bit
`del_w_r`/`ins_w_r` pipeline registers of all 14 stages, which placement spreads
across the whole die, so the muxes were fed by 14 long 48-bit buses. Two central
register files mirror those values next to their only consumer:
`vpipe[j]` (the carried V of the delete issued *j* cycles ago — V is invariant
down a sift, so `vpipe[j-1] == del_w_r[j]`) and `cwr[j]` (an exact copy of
`ins_w_r[j]`, same source, same edge). `sb_data` reads `vpipe`, and `le_val` /
`land_data_c` read `cwr`; only 1-bit hit signals now travel from the stages.
The transform is bit-exact — verified by identical simulation results — and it
does move the 48-bit buses out of the cone (the post-route worst path no longer
sources from a stage register). It did **not** measurably improve WNS, because
the next-worst cones sit at essentially the same delay; see §10.

**Occupancy clamp restructure**: per-stage child occupancy uses
`x ≤ min(bound, clamp)` decomposed into two parallel compares
(`x ≤ bound && (!del_acc || x ≤ count−1)`) so the issue-cycle clamp adds one
LUT, not a serial 15-bit min, in front of the compare tree.

## 6. Write-history forwarding (local bypasses)

BRAM read data can be stale w.r.t. writes committed at the array-read edge or
later. With use-time = compare cycle, the missed writers are exactly ops issued
1 and 2 cycles before the consumer (the 1-cycle-ahead case for a delete's
children read would be an op issued d−1: impossible for a delete (bubble rule)
or an aborted insert — it vanishes; all remaining cases are covered by the
depth-2 history):

* Insert node value at level L, used cycle i+L−1: missed writes commit at ends
  of i+L−3 (op issued i−2) and i+L−2 (op issued i−1) → history entries age 2
  and 1. ✓
* Delete children (level L+1 data), used cycle d+L−1: missed writes commit at
  ends of d+L−3 (op d−3) and d+L−2 (op d−2) → ages 2 and 1. ✓ (op d−1: none.)
* Ops ≥3 cycles apart: write commits strictly before the consumer's array-read
  edge → RAM content is current. ✓
* FF levels (2–4) are read combinationally in the compare cycle → always
  current. ✓

History is per level, written unconditionally on every commit to that level;
consumers compare full local addresses (per lane for the 4-wide data).

## 7. Port-conflict audit (2-port = 1R + 1W per level)

Read port of BRAM level M, edge at end of cycle t:

| User | Edge | Conflict condition | Resolution |
|---|---|---|---|
| Insert i (path read) | end(i+M−3) | vs delete d grandchild read: d = i+1 | that delete aborts insert i (youngest) in cycle d = i+1 ≤ i+M−4+1 < read edge → read suppressed in time |
| Delete d (grandchild) | end(d+M−4) | vs other deletes: never (≥2 apart ⇒ distinct edges) | — |
| Prefetch (delete d, m=0) | end(d+q), q=0,1,2 (retry) | vs insert/delete reads | fixed priority: delete > insert > prefetch; blocked-by-insert ⇒ live insert covers the slot (proof in NOTES); delete traffic has fixed parity ⇒ ≥1 free edge |

Write port of level M, edge end(t): writer is the op issued t−M+1 (both op
types write level M at end of issue+M−1) — at most one op issues per cycle ⇒
**never two writers**. Same-edge read+write to the same address behaves
read-first; correctness restored by history forwarding.

## 8. Issue rules & interface behavior

* `ready_ins = ~full` (full: count == 16383). One insert per cycle sustained.
* `ready_del = ~empty && ~del_bubble`; `del_bubble` is set for exactly one
  cycle after any accepted delete (paper §III-C: avoids the global bypass
  network). Delete may issue the cycle right after an insert (abort supplies
  the bubble); insert may issue the cycle right after anything.
* Issuing with `op` ≠ NOP while the corresponding ready is low is a testbench
  error; DUT behavior undefined (it will ignore ready and corrupt state).
* `count`/`empty`/`full` update at the end of the issue cycle.

## 9. Hazard enumeration (each maps to a directed test)

| # | Hazard | Resolution | Test |
|---|---|---|---|
| H1 | I-after-op, same path, every level (chasing): read stale vs op 1 ahead | history-1 forwarding | `t_hz_ii_chase` (descending keys), `t_hz_di_chase` |
| H2 | I-after-op, op 2 ahead (write at array-read edge) | history-2 forwarding | `t_hz_gap2_chase` |
| H3 | D-after-I next cycle: level-2 read stale | insert aborted ⇒ bubble; refill = aborted value | `t_hz_id_abort` (abort at depths 1..14 via spacing sweep) |
| H4 | D-after-D next cycle | **banned** by `ready_del` bubble | `t_ready_rules` |
| H5 | D-bubble-D chasing same path (paper Fig. 6 pattern, legal spacing 2) | history-2 on children data | `t_hz_dd_chase` |
| H6 | D steals slot an in-flight sift is entering (same cycle) | same-cycle bound clamp (§4) excludes the slot before pull-up | `t_hz_steal_race` |
| H7 | D steals slot an in-flight sift already entered (write pending/committed) | write snoop + same-cycle steal forward (§5) | `t_hz_steal_late` |
| H8 | Older D's sift vs slot reused by newer D + newer I (garbage memory) | frozen bound + clamp: slot excluded for the older D | `t_hz_bound_reuse` |
| H9 | Insert landing exactly when a delete issues | landing counts as live: write suppressed, value stolen | `t_hz_land_steal` |
| H10 | Landing write vs 2-cycles-later delete's children read | history forwarding (landing is an ordinary write) | `t_hz_land_read` |
| H11 | m=0 delete chains every 2 cycles across level boundaries | dual shadow + prefetch retry/forward | `t_hz_drain_chain` (drain across 2^k occupancies) |
| H12 | Prefetch port collision (delete grandchild @ same level) | retry on off-parity edge; forward-on-arrival | `t_hz_prefetch_clash` |
| H13 | Structural: two writes same level same cycle | impossible by schedule (§7) | audit + yosys/assertions |
| H14 | Duplicate keys / ties everywhere | tie rules: resident stays (insert), parent stays (delete), left child preferred | `t_dup_keys` |

## 10. Why 250 MHz is not reached (measured)

Post-route on the -1 Artix proxy the design closes at **12.5 ns**, not 4.0 ns.
The limit is not one cone but a *family* of cones of near-identical delay, all
route-dominated (60–79 % of the path is routing):

| Cone | a100t-1 @4 ns | Structure |
|---|---|---|
| `count_r` → `refill_r` | −8.138 (12.09 ns, 16 levels, 6×CARRY4) | `count_next` fans out to fourteen 15-bit `== count_next` comparators, one per stage, then the hit bits gather back to the central refill mux |
| `ins_k_r` → BRAM `WEBWE` | −8.070 (11.45 ns, 13 levels) | `pL = it >> (ik - L)` variable shift → local address → write enable |

The two are within 0.07 ns, so removing either one alone gains nothing (this is
exactly what the `vpipe`/`cwr` rework demonstrated: it emptied the first cone of
its 48-bit buses and WNS moved by 0.078 ns). The root cause is structural — a
14-stage design whose central issue logic must talk to every stage in one cycle,
placed across the full die height. Closing 250 MHz would need locality, not
retiming:

* precompute the fourteen `del_n_r == count_next` compares one cycle early
  against the six candidates (`count_next(t-1)+{-1,0,+1}` × `b_dir ∈ {0,1}`),
  reducing the issue-cycle work to a 6:1 select of registered 1-bit signals —
  the same candidate-compare idiom §5 already uses for the shadow snoop;
* give the issue cycle its own pipeline stage ("+1 stage-0 shift", requires the
  delete result to become `min(root, pending stage-0 insert)` and a full hazard
  re-audit);
* floorplan with pblocks so each level column sits near the shadow/refill logic.

Note also that Vivado *degrades* this design as the constraint is relaxed (at
14 ns the same cone is rebuilt with 18 levels / 5.86 ns of logic versus 16
levels / 4.74 ns at 4 ns), so a plain period sweep never crosses zero; the
closing periods in SUMMARY.md were found with the aggressive-directive flow,
which keeps optimization effort up.

## 11. Deviations from the written spec

* Capacity is 16383 entries (= 2^14 − 1, complete binary tree), not 16384.
* `replaceMin` omitted (per spec, matching the paper's implementation).
* Plain unsigned comparison (wrap-around comparison not required by spec).
