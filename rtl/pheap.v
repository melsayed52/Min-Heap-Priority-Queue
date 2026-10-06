// pheap.v - Pipelined binary min-heap priority queue.
//
// Architecture: Ioannou & Katevenis, IEEE/ACM ToN 15(2) 2007, version (ii):
// one pipeline stage per heap level, 2-port 4-wide memories, operations
// ripple down one level per clock. Sustained rates: 1 insert/cycle,
// 1 delete-min per 2 cycles (delete may follow an insert immediately -
// that insert is aborted and its value becomes the root refill).
//
// See docs/ARCHITECTURE.md for the full pipeline schedule, hazard list and
// the lastEntry / shadow-register scheme. Stage logic lives in generate
// blocks in this file (dense cross-level wiring); ram_dp.v is the only
// submodule.
//
// Levels 1..FF_TOP(=4) are flip-flop arrays read combinationally in the
// compare cycle. Levels 5..LEVELS are four ram_dp banks per level (4-wide
// read word, single-entry write) with a depth-2 write history providing the
// paper's "local bypasses from the two stages below".
`default_nettype none

module pheap #(
  parameter LEVELS = 14,
  parameter KEY_W  = 32,
  parameter ID_W   = 16
)(
  input  wire              clk,
  input  wire              rst,        // synchronous, active high
  // command interface (one cmd per cycle)
  input  wire [1:0]        op,         // 00=NOP, 01=INSERT, 10=DELETE_MIN
  input  wire [KEY_W-1:0]  ins_key,
  input  wire [ID_W-1:0]   ins_id,
  output wire              ready_ins,  // can accept INSERT this cycle
  output wire              ready_del,  // can accept DELETE_MIN this cycle
  // delete result (registered; 1 cycle after the delete is accepted)
  output reg               del_valid,
  output reg  [KEY_W-1:0]  del_key,
  output reg  [ID_W-1:0]   del_id,
  // status
  output wire [LEVELS:0]   count,      // current occupancy (0..2^LEVELS-1)
  output wire              full,
  output wire              empty
);

  localparam ENT    = KEY_W + ID_W;      // entry width (48)
  localparam IW     = LEVELS + 1;        // index/count width (15)
  localparam LW     = 4;                 // level-number width
  localparam AWX    = LEVELS - 1;        // max local-address width (13)
  localparam WWX    = LEVELS - 3;        // max word-address width (11)
  localparam D2W    = 4*ENT;             // 4-wide read data width (192)
  localparam NS     = LEVELS + 1;        // bus slot count (index by level 1..LEVELS)
  localparam FF_TOP = 4;                 // levels <= FF_TOP are flip-flop arrays
  localparam [IW-1:0] CAP = (1 << LEVELS) - 1;

  // ---------------------------------------------------------------------
  // Functions
  // ---------------------------------------------------------------------
  // Level of a global node index = position of its MSB (1-based).
  function [LW-1:0] lvl_of;
    input [IW-1:0] x;
    integer i;
    begin
      lvl_of = 0;
      for (i = 1; i <= LEVELS; i = i + 1)
        if (x[i-1]) lvl_of = i;
    end
  endfunction

  // ---------------------------------------------------------------------
  // Op pipeline registers (slot L = op whose compare-at-level-L happens
  // this cycle) and inter-stage combinational buses.
  // ---------------------------------------------------------------------
  reg  [NS-1:0]        ins_v_r;   // live insert resident at stage L
  reg  [NS*ENT-1:0]    ins_w_r;   // traveling entry
  reg  [NS*IW-1:0]     ins_t_r;   // target slot (global index)
  reg  [NS*LW-1:0]     ins_k_r;   // target level
  reg  [NS-1:0]        del_v_r;   // delete sift resident at stage L
  reg  [NS*ENT-1:0]    del_w_r;   // sinking value V
  reg  [NS*IW-1:0]     del_n_r;   // node being (re)written at level L (global)
  reg  [NS*IW-1:0]     del_b_r;   // occupancy bound for this sift

  wire [NS-1:0]        nx_ins_v,  nx_del_v;
  wire [NS*ENT-1:0]    nx_ins_w,  nx_del_w;
  wire [NS*IW-1:0]     nx_ins_t,  nx_del_n, nx_del_b;
  wire [NS*LW-1:0]     nx_ins_k;

  // Per-level write buses (level 2..LEVELS; level 1 = root handled separately)
  wire [NS-1:0]        w_we;
  wire [NS*AWX-1:0]    w_addr;    // local address, zero-extended
  wire [NS*ENT-1:0]    w_data;
  wire [NS*IW-1:0]     w_gaddr;   // global address (for last-entry snooping)

  wire [NS-1:0]        land_v;    // insert landing commit this cycle at stage L
  wire [NS-1:0]        b_dir;     // delete direction bit chosen at stage L (comb)
  wire [NS-1:0]        killed;    // abort strobe per stage

  // BRAM interconnect (levels FF_TOP+1..LEVELS)
  wire [NS*WWX-1:0]    ram_raddr; // (debug/visibility; driven in g_ram)
  wire [NS*D2W-1:0]    ram_do;    // 4-wide registered read data per level
  wire [NS*WWX-1:0]    ram_rw1;   // word address matching current ram_do
  wire [NS-1:0]        h0_v, h1_v;         // write history (age 1, age 2)
  wire [NS*AWX-1:0]    h0_a, h1_a;
  wire [NS*ENT-1:0]    h0_d, h1_d;
  wire [NS-1:0]        pf_gnt;    // prefetch read grant per level

  // Flip-flop levels 2..4
  reg  [2*ENT-1:0]     ff2;
  reg  [4*ENT-1:0]     ff3;
  reg  [8*ENT-1:0]     ff4;

  // ---------------------------------------------------------------------
  // Stage 1: interface, occupancy, root, lastEntry, abort, shadows
  // ---------------------------------------------------------------------
  reg  [IW-1:0]  count_r;
  reg  [ENT-1:0] root_r;
  reg            bub_r;       // one-cycle delete-after-delete bubble

  wire ins_acc, del_acc;
  wire [IW-1:0] count_next;

  // ---- live-insert bookkeeping / abort (all register-sourced) ----
  // The issue-cycle logic must stay shallow: everything a delete consumes at
  // issue (refill value, readiness, kill target) is either a register or a
  // one-level function of registers. Deep quantities are computed one cycle
  // ahead from the stages' next-state signals and registered.
  wire m_ge1 = |ins_v_r[NS-1:2];

  // Youngest live insert as a registered one-hot: nx_ins_v[L] means "will be
  // at stage L+1 next cycle"; priority-encode the next-state flags.
  wire [NS-1:0] young_nx;
  reg  [NS-1:0] young_r;
  genvar gy;
  generate
    for (gy = 1; gy <= LEVELS-1; gy = gy + 1) begin : g_yng
      if (gy == 1) assign young_nx[1] = nx_ins_v[1];
      else         assign young_nx[gy] = nx_ins_v[gy] && !(|nx_ins_v[gy-1:1]);
    end
  endgenerate
  assign young_nx[0] = 1'b0;
  assign young_nx[NS-1] = 1'b0;

  wire kill_req = del_acc && m_ge1;
  genvar gk;
  generate
    for (gk = 2; gk <= LEVELS; gk = gk + 1) begin : g_kill
      assign killed[gk] = kill_req && young_r[gk];
    end
  endgenerate
  assign killed[1] = 1'b0;
  assign killed[0] = 1'b0;

  // ---- landing bookkeeping ----
  wire [NS-1:0] wland;   // per-stage "insert lands here this cycle" (regs)

  // Settled last slot S = count - (#live inserts), kept as a register with a
  // shallow event-based update: +1 on any landing commit (incl. an insert
  // landing straight at the empty root), -1 on an m==0 delete.
  reg  [IW-1:0] S_r;
  wire land_any_pre = |wland[NS-1:2];                    // lander present
  wire yland = |(wland[NS-1:2] & young_r[NS-1:2]);       // lander is youngest
  wire land_commit_any = land_any_pre && !(kill_req && yland);
  wire s_up   = land_commit_any || (ins_acc && (count_r == 0));
  wire s_down = del_acc && !m_ge1;
  wire [IW-1:0] S_next = S_r + {14'b0, s_up} - {14'b0, s_down};

  // Triple shadow: lastVal/lastVal2/lastVal3 = values of slots S, S-1, S-2.
  // Three deep gives the lastVal3 prefetch a full two delete-periods of
  // margin, so prefetch data only ever enters the shadows through registers.
  reg            lv_v,  lv2_v,  lv3_v;
  reg  [ENT-1:0] lastVal, lastVal2, lastVal3;

  // ---- one-cycle-delayed global write record (snoop source) ----
  // Registered copy of every level's write (address as global heap index).
  // Shadow-register snooping keys off these instead of the same-cycle write
  // buses, keeping the write-data compare cones out of the issue cycle. The
  // one-cycle lag is covered case-by-case: sift writes into the consumed
  // slot forward through steal_now/refill_B (register-sourced), landings
  // forward directly from the lander's registers, and every other writer of
  // a shadow slot is only consumed >=2 cycles later (see NOTES.md).
  reg  [NS-1:0]      gwr_v;
  reg  [NS*IW-1:0]   gwr_a;
  reg  [NS*ENT-1:0]  gwr_d;

  // ---- prefetch machinery (fills lastVal3 after an m==0 delete) ----
  reg           pf_pend;
  reg [IW-1:0]  pf_slot;
  reg [LW-1:0]  pf_lvl;
  reg [WWX-1:0] pf_word;
  reg [1:0]     pf_lane;
  reg           g0_v, g1_v;
  reg [IW-1:0]  g0_slot, g1_slot;
  reg [LW-1:0]  g0_lvl,  g1_lvl;
  reg [1:0]     g0_lane, g1_lane;

  wire pf_granted = |pf_gnt;
  wire arr_v = g1_v;
  wire [ENT-1:0] arr_d = ram_do[(g1_lvl*D2W + {8'b0,g1_lane}*ENT) +: ENT];

  integer wj, wk;

  // ---- refill (lastEntry) for a delete: fully pre-registered ----
  // Everything a delete issued at t+1 (consuming slot count_next) needs is
  // computed during t and registered, so the issue-cycle root compare sees
  // only refill_r/refill_vld_r flip-flops. Sources, mutually exclusive by
  // construction (see NOTES.md):
  //   P: a sift ENTERS slot count_next at t+1 and writes its carried V
  //      there at the end of t+1 (the last slot's children are always
  //      empty, so the write value is the register del_w_r, unchanged);
  //   B: a sift ON slot count_next at t settles there at the end of t
  //      (same register-sourced V);
  //   A: a live insert exists at t+1 - the youngest's traveling value
  //      (abort bypass). This one is NOT pre-registered: at issue time it
  //      is a shallow one-hot mux of pipeline registers (young_r x ins_w_r);
  //   C: the shadow chain's next lastVal (covers the settled value and an
  //      insert landing on slot count_next this cycle).
  reg            refill_vld_r;
  reg  [ENT-1:0] refill_r;   // P/B/C data only; A muxed in at issue

  // Central mirrors of far-away pipeline registers, so the refill gather
  // muxes see local flip-flops and only 1-bit hit signals cross the die:
  //  - vpipe[j] = the carried V of the delete issued j cycles ago (V never
  //    changes as a sift descends, so this equals del_w_r of its stage);
  //  - cwr[j]   = mirror of ins_w_r[j] (traveling insert values).
  reg  [NS*ENT-1:0] vpipe;
  reg  [NS*ENT-1:0] cwr;
  integer wm;                       // private to this process (do not share wk)
  always @(posedge clk) begin
    vpipe[1*ENT +: ENT] <= nx_del_w[1*ENT +: ENT];   // == refill (declared below)
    for (wm = 2; wm <= LEVELS; wm = wm + 1)
      vpipe[wm*ENT +: ENT] <= vpipe[(wm-1)*ENT +: ENT];
    for (wm = 2; wm <= LEVELS; wm = wm + 1)
      cwr[wm*ENT +: ENT] <= nx_ins_w[(wm-1)*ENT +: ENT];
  end

  wire ref_a_v = |nx_ins_v[NS-2:1];
  reg  ref_b_v;
  reg  steal_pred_c;
  reg  [ENT-1:0] sb_data;    // shared P/B data (exclusive sources)

  // The refill compare (does any stage's node equal the slot a delete at t+1
  // will consume, i.e. count_next?) used to feed the fourteen 15-bit
  // comparators from `count_next`, which is `count_r` through a 15-bit
  // incrementer (4 CARRY4) plus a fanout-42 broadcast net - ~5 ns of the
  // critical cone before any comparison starts. Since ins_acc/del_acc are
  // mutually exclusive, count_next is always exactly one of
  // {count_r-1, count_r, count_r+1}. We pre-register the two shifted
  // candidates (count_r itself is already a register), so the comparators are
  // register-fed and start at the clock edge; ins_acc/del_acc then only steer
  // a 1-bit select of the finished compare results. Bit-identical to the old
  // `== count_next` form.
  reg [IW-1:0] candm1_r, candp1_r;   // == count_r-1, count_r+1 at cycle t
  always @(posedge clk) begin
    candm1_r <= count_next - 1'b1;   // no reset needed: unused when unselected
    candp1_r <= count_next + 1'b1;   // (del_acc/ins_acc gate the selection)
  end

  always @* begin
    ref_b_v = 1'b0;
    steal_pred_c = 1'b0;
    sb_data = {ENT{1'b0}};
    for (wj = 2; wj <= LEVELS; wj = wj + 1) begin
      // B: sift resident on the consumed slot settles there. Compare the
      // registered node against the three registered candidates in parallel;
      // the ternary is a late 1-bit select, == (del_n_r == count_next).
      if (del_v_r[wj] &&
          (del_acc  ? (del_n_r[wj*IW +: IW] == candm1_r)
           : ins_acc ? (del_n_r[wj*IW +: IW] == candp1_r)
           :           (del_n_r[wj*IW +: IW] == count_r))) begin
        ref_b_v = 1'b1;
        sb_data = sb_data | vpipe[(wj-1)*ENT +: ENT];
      end
      // P: sift ENTERS the consumed slot (child index {node,b_dir}) next cycle.
      // {del_n_r[IW-2:0], b_dir} == cand  <=>  hi bits match (register-fed)
      // AND b_dir == cand[0]; keeps the combinational b_dir out of the wide
      // comparator (only a final 1-bit XNOR), == the old b_dir-muxed form.
      if (wj < LEVELS && nx_del_v[wj] &&
          (del_acc  ? ((del_n_r[wj*IW +: IW-1] == candm1_r[IW-1:1]) && (b_dir[wj] == candm1_r[0]))
           : ins_acc ? ((del_n_r[wj*IW +: IW-1] == candp1_r[IW-1:1]) && (b_dir[wj] == candp1_r[0]))
           :           ((del_n_r[wj*IW +: IW-1] == count_r[IW-1:1])  && (b_dir[wj] == count_r[0])))) begin
        steal_pred_c = 1'b1;
        sb_data = sb_data | vpipe[(wj-1)*ENT +: ENT];
      end
    end
    // a delete issued this very cycle whose sift enters slot count_next at
    // t+1 (only possible for tiny heaps: stage-1 hand-off)
    if (nx_del_v[1] &&
        (del_acc  ? (nx_del_n[1*IW +: IW] == candm1_r)
         : ins_acc ? (nx_del_n[1*IW +: IW] == candp1_r)
         :           (nx_del_n[1*IW +: IW] == count_r))) begin
      steal_pred_c = 1'b1;
      sb_data = sb_data | nx_del_w[1*ENT +: ENT];
    end
  end

  // youngest live insert's traveling value, registers only (issue cycle)
  reg [ENT-1:0] le_val;
  integer sj;
  always @* begin
    le_val = {ENT{1'b0}};
    for (sj = 2; sj <= LEVELS; sj = sj + 1)
      if (young_r[sj]) le_val = le_val | cwr[sj*ENT +: ENT];
  end

  wire [ENT-1:0] refill = m_ge1 ? le_val : refill_r;
  wire refill_ok = (count_r == {{IW-1{1'b0}},1'b1}) || refill_vld_r;

  // ---- accept / ready ----
  assign ready_ins = (count_r != CAP) && !rst;
  assign ready_del = (count_r != 0) && !bub_r && refill_ok && !rst;
  assign ins_acc = (op == 2'b01) && ready_ins;
  assign del_acc = (op == 2'b10) && ready_del;
  assign count_next = count_r + {14'b0, ins_acc} - {14'b0, del_acc};
  // count_r - 1 == count_next whenever del_acc; computed off the register so
  // the per-stage occupancy clamps compare in parallel with the bound check
  wire [IW-1:0] count_rm1 = count_r - 1'b1;

  assign count = count_r;
  assign full  = (count_r == CAP);
  assign empty = (count_r == 0);

  // ---- insert issue (compare at level 1) ----
  wire [IW-1:0]  Tins  = count_r + 1'b1;
  wire [LW-1:0]  kins  = lvl_of(Tins);
  wire [ENT-1:0] Wins  = {ins_key, ins_id};
  wire           land1 = (count_r == 0);
  wire ins_wsm = Wins[ENT-1:ID_W] < root_r[ENT-1:ID_W];

  // ---- delete issue (compare at level 1) ----
  wire [IW-1:0] bnd1 = count_next;                 // this delete's frozen bound
  wire del_sift = del_acc && (count_next != 0);
  wire [ENT-1:0] c0v_1 = ff2[0*ENT +: ENT];
  wire [ENT-1:0] c1v_1 = ff2[1*ENT +: ENT];
  wire occ0_1 = (15'd2 <= bnd1);
  wire occ1_1 = (15'd3 <= bnd1);
  wire vle0_1 = refill[ENT-1:ID_W] <= c0v_1[ENT-1:ID_W];
  wire vle1_1 = refill[ENT-1:ID_W] <= c1v_1[ENT-1:ID_W];
  wire c01_1  = c0v_1[ENT-1:ID_W] <= c1v_1[ENT-1:ID_W];
  wire settle_1 = !occ0_1 || (occ1_1 ? (vle0_1 && vle1_1) : vle0_1);
  wire pick1_1  = occ1_1 && !c01_1;
  wire [ENT-1:0] dmin_1 = settle_1 ? refill : (pick1_1 ? c1v_1 : c0v_1);

  // ---- root register / result ----
  wire root_we = ins_acc | del_sift;
  wire [ENT-1:0] root_nx = ins_acc ? ((land1 | ins_wsm) ? Wins : root_r)
                                   : dmin_1;
  always @(posedge clk) begin
    if (root_we) root_r <= root_nx;
    del_valid <= del_acc && !rst;
    if (del_acc) begin
      del_key <= root_r[ENT-1:ID_W];
      del_id  <= root_r[ID_W-1:0];
    end
    if (rst) begin
      count_r <= 0;
      bub_r   <= 0;
    end else begin
      count_r <= count_next;
      bub_r   <= del_acc;
    end
  end

  // ---- pipe out of stage 1 ----
  assign nx_ins_v[1] = ins_acc && !land1;
  assign nx_ins_w[1*ENT +: ENT] = ins_wsm ? root_r : Wins;
  assign nx_ins_t[1*IW +: IW]   = Tins;
  assign nx_ins_k[1*LW +: LW]   = kins;
  assign nx_del_v[1] = del_sift && !settle_1;
  assign nx_del_w[1*ENT +: ENT] = refill;
  assign nx_del_n[1*IW +: IW]   = pick1_1 ? 15'd3 : 15'd2;
  assign nx_del_b[1*IW +: IW]   = bnd1;
  assign b_dir[1] = pick1_1;

  // tie off unused slot-0 bus bits
  assign nx_ins_v[0] = 1'b0;
  assign nx_del_v[0] = 1'b0;
  assign nx_ins_w[0*ENT +: ENT] = {ENT{1'b0}};
  assign nx_del_w[0*ENT +: ENT] = {ENT{1'b0}};
  assign nx_ins_t[0*IW +: IW] = {IW{1'b0}};
  assign nx_del_n[0*IW +: IW] = {IW{1'b0}};
  assign nx_del_b[0*IW +: IW] = {IW{1'b0}};
  assign nx_ins_k[0*LW +: LW] = {LW{1'b0}};
  assign b_dir[0] = 1'b0;
  assign w_we[0] = 1'b0; assign w_we[1] = 1'b0;
  assign w_addr[0*AWX +: 2*AWX] = {2*AWX{1'b0}};
  assign w_data[0*ENT +: 2*ENT] = {2*ENT{1'b0}};
  assign w_gaddr[0*IW +: IW] = {IW{1'b0}};
  assign w_gaddr[1*IW +: IW] = 15'd1;     // root's global address
  assign land_v[0] = 1'b0; assign land_v[1] = 1'b0;

  // ---------------------------------------------------------------------
  // Snoop of last cycle's writes (gwr) against the shadow slots.
  // S_next is one of {S_r-1, S_r, S_r+1}, so every address comparison is
  // done register-vs-register against the five candidate slots S_r+1 ..
  // S_r-3 in parallel, and the event bits (s_up/s_down) only steer the
  // final selection - this keeps the accept logic off the compare chains.
  // ---------------------------------------------------------------------
  wire [IW-1:0] Sp1 = S_r + 1'b1;
  wire [IW-1:0] Sm1 = S_r - 1'b1;
  wire [IW-1:0] Sm2 = S_r - 2'd2;
  wire [IW-1:0] Sm3 = S_r - 2'd3;

  reg [NS-1:0] gm_p1, gm_0, gm_m1, gm_m2, gm_m3;
  always @* begin
    for (wj = 0; wj <= LEVELS; wj = wj + 1) begin
      gm_p1[wj] = gwr_v[wj] && (gwr_a[wj*IW +: IW] == Sp1);
      gm_0[wj]  = gwr_v[wj] && (gwr_a[wj*IW +: IW] == S_r);
      gm_m1[wj] = gwr_v[wj] && (gwr_a[wj*IW +: IW] == Sm1);
      gm_m2[wj] = gwr_v[wj] && (gwr_a[wj*IW +: IW] == Sm2);
      gm_m3[wj] = gwr_v[wj] && (gwr_a[wj*IW +: IW] == Sm3);
    end
    gm_p1[0] = 1'b0; gm_0[0] = 1'b0; gm_m1[0] = 1'b0;
    gm_m2[0] = 1'b0; gm_m3[0] = 1'b0;
  end

  // per-candidate snoop hit + data (register-vs-register, fully parallel)
  reg gv_p1, gv_0, gv_m1, gv_m2, gv_m3;
  reg [ENT-1:0] gd_p1, gd_0, gd_m1, gd_m2, gd_m3;
  always @* begin
    gv_p1 = |gm_p1; gv_0 = |gm_0; gv_m1 = |gm_m1;
    gv_m2 = |gm_m2; gv_m3 = |gm_m3;
    gd_p1 = {ENT{1'b0}}; gd_0 = {ENT{1'b0}}; gd_m1 = {ENT{1'b0}};
    gd_m2 = {ENT{1'b0}}; gd_m3 = {ENT{1'b0}};
    for (wj = 1; wj <= LEVELS; wj = wj + 1) begin
      if (gm_p1[wj]) gd_p1 = gd_p1 | gwr_d[wj*ENT +: ENT];
      if (gm_0[wj])  gd_0  = gd_0  | gwr_d[wj*ENT +: ENT];
      if (gm_m1[wj]) gd_m1 = gd_m1 | gwr_d[wj*ENT +: ENT];
      if (gm_m2[wj]) gd_m2 = gd_m2 | gwr_d[wj*ENT +: ENT];
      if (gm_m3[wj]) gd_m3 = gd_m3 | gwr_d[wj*ENT +: ENT];
    end
  end

  // prefetch-arrival slot matches per candidate (registers only)
  wire ar_0  = arr_v && (g1_slot == S_r);
  wire ar_m1 = arr_v && (g1_slot == Sm1);
  wire ar_m2 = arr_v && (g1_slot == Sm2);
  wire ar_m3 = arr_v && (g1_slot == Sm3);

  // landing flags/data straight from op registers (kill only matters for
  // the commit decision, which is folded into s_up)
  genvar gl;
  generate
    for (gl = 2; gl <= LEVELS; gl = gl + 1) begin : g_wl
      assign wland[gl] = ins_v_r[gl] && (ins_k_r[gl*LW +: LW] == gl);
    end
  endgenerate
  assign wland[1] = 1'b0;
  assign wland[0] = 1'b0;

  reg [ENT-1:0] land_data_c;
  integer lj;
  always @* begin
    land_data_c = Wins;                    // insert landing at the empty root
    for (lj = 2; lj <= LEVELS; lj = lj + 1)
      if (wland[lj]) land_data_c = cwr[lj*ENT +: ENT];
  end

  // FF-level read of slot Sm3 (the only slot a shift-down must fetch)
  reg [ENT-1:0] ffprd;
  always @* begin
    ffprd = {ENT{1'b0}};
    if (Sm3 == 15'd1)                       ffprd = root_r;
    else if (Sm3 >= 15'd2 && Sm3 <= 15'd3)  ffprd = ff2[(Sm3-2)*ENT +: ENT];
    else if (Sm3 >= 15'd4 && Sm3 <= 15'd7)  ffprd = ff3[(Sm3-4)*ENT +: ENT];
    else if (Sm3 >= 15'd8 && Sm3 <= 15'd15) ffprd = ff4[(Sm3-8)*ENT +: ENT];
  end
  wire sm3_is_ff = (S_r >= 4) && (lvl_of(Sm3) <= 4'd4);

  // ---------------------------------------------------------------------
  // Shadow next-state, computed as three fully parallel banks (landing /
  // hold / m==0-delete) that only see registers; s_up/s_down (which depend
  // on this cycle's accept) select between the finished banks at the end.
  // Source priority inside each bank, newest write first:
  //   landing (commits end of THIS cycle, register-sourced data)
  //   > gwr snoop (committed end of last cycle)
  //   > shift/hold (register state)
  //   > prefetch arrival (array data, fills only an invalid slot)
  // ---------------------------------------------------------------------
  // slot validity per case
  wire ge1 = (S_r >= 1), ge2 = (S_r >= 2), ge3 = (S_r >= 3), ge4 = (S_r >= 4);

  // lv (slot: up->S_r+1, hold->S_r, dn->S_r-1)
  wire        lvU_v = 1'b1;
  wire [ENT-1:0] lvU_d = land_data_c;
  wire        lvH_p = gv_0 ? 1'b1 : lv_v;
  wire [ENT-1:0] lvH_pd = gv_0 ? gd_0 : lastVal;
  wire        lvH_v = (lvH_p || ar_0) && ge1;
  wire [ENT-1:0] lvH_d = lvH_p ? lvH_pd : arr_d;
  wire        lvD_p = gv_m1 ? 1'b1 : lv2_v;
  wire [ENT-1:0] lvD_pd = gv_m1 ? gd_m1 : lastVal2;
  wire        lvD_v = (lvD_p || ar_m1) && ge2;
  wire [ENT-1:0] lvD_d = lvD_p ? lvD_pd : arr_d;

  // lv2 (slot: up->S_r, hold->S_r-1, dn->S_r-2)
  wire        l2U_p = gv_0 ? 1'b1 : lv_v;
  wire [ENT-1:0] l2U_pd = gv_0 ? gd_0 : lastVal;
  wire        l2U_v = (l2U_p || ar_0) && ge1;
  wire [ENT-1:0] l2U_d = l2U_p ? l2U_pd : arr_d;
  wire        l2H_p = gv_m1 ? 1'b1 : lv2_v;
  wire [ENT-1:0] l2H_pd = gv_m1 ? gd_m1 : lastVal2;
  wire        l2H_v = (l2H_p || ar_m1) && ge2;
  wire [ENT-1:0] l2H_d = l2H_p ? l2H_pd : arr_d;
  wire        l2D_p = gv_m2 ? 1'b1 : lv3_v;
  wire [ENT-1:0] l2D_pd = gv_m2 ? gd_m2 : lastVal3;
  wire        l2D_v = (l2D_p || ar_m2) && ge3;
  wire [ENT-1:0] l2D_d = l2D_p ? l2D_pd : arr_d;

  // lv3 (slot: up->S_r-1, hold->S_r-2, dn->S_r-3)
  wire        l3U_p = gv_m1 ? 1'b1 : lv2_v;
  wire [ENT-1:0] l3U_pd = gv_m1 ? gd_m1 : lastVal2;
  wire        l3U_v = (l3U_p || ar_m1) && ge2;
  wire [ENT-1:0] l3U_d = l3U_p ? l3U_pd : arr_d;
  wire        l3H_p = gv_m2 ? 1'b1 : lv3_v;
  wire [ENT-1:0] l3H_pd = gv_m2 ? gd_m2 : lastVal3;
  wire        l3H_v = (l3H_p || ar_m2) && ge3;
  wire [ENT-1:0] l3H_d = l3H_p ? l3H_pd : arr_d;
  wire        l3D_p = gv_m3 ? 1'b1 : (sm3_is_ff ? 1'b1 : 1'b0);
  wire [ENT-1:0] l3D_pd = gv_m3 ? gd_m3 : ffprd;
  wire        l3D_v = (l3D_p || ar_m3) && ge4;
  wire [ENT-1:0] l3D_d = l3D_p ? l3D_pd : arr_d;

  // final case select (s_up/s_down arrive late but only steer 3:1 muxes)
  wire            lv_v_n  = s_up ? lvU_v : s_down ? lvD_v : lvH_v;
  wire [ENT-1:0]  lv_n    = s_up ? lvU_d : s_down ? lvD_d : lvH_d;
  wire            lv2_v_n = s_up ? l2U_v : s_down ? l2D_v : l2H_v;
  wire [ENT-1:0]  lv2_n   = s_up ? l2U_d : s_down ? l2D_d : l2H_d;
  wire            lv3_v_n = s_up ? l3U_v : s_down ? l3D_v : l3H_v;
  wire [ENT-1:0]  lv3_n   = s_up ? l3U_d : s_down ? l3D_d : l3H_d;

  wire pf_launch = s_down && ge4 && !l3D_v && !sm3_is_ff;

  wire [IW-1:0]  pf_tgt_loc_w = Sm3 - (15'd1 << (lvl_of(Sm3) - 1'b1));

  always @(posedge clk) begin
    if (rst) begin
      lv_v <= 1'b0; lv2_v <= 1'b0; lv3_v <= 1'b0;
      pf_pend <= 1'b0; g0_v <= 1'b0; g1_v <= 1'b0;
      lastVal <= {ENT{1'b0}}; lastVal2 <= {ENT{1'b0}}; lastVal3 <= {ENT{1'b0}};
      pf_slot <= 0; pf_lvl <= 0; pf_word <= 0; pf_lane <= 0;
      g0_slot <= 0; g0_lvl <= 0; g0_lane <= 0;
      g1_slot <= 0; g1_lvl <= 0; g1_lane <= 0;
      S_r <= 0; young_r <= 0;
      refill_vld_r <= 1'b0; refill_r <= {ENT{1'b0}};
      gwr_v <= 0;
    end else begin
      lv_v  <= lv_v_n;  lastVal  <= lv_n;
      lv2_v <= lv2_v_n; lastVal2 <= lv2_n;
      lv3_v <= lv3_v_n; lastVal3 <= lv3_n;
      S_r <= S_next;
      young_r <= {young_nx[NS-2:1], 2'b00};
      refill_vld_r <= ref_a_v | ref_b_v | steal_pred_c | lv_v_n;
      refill_r     <= (steal_pred_c | ref_b_v) ? sb_data : lv_n;
      // one-cycle-delayed write record for snooping
      gwr_v[1] <= root_we;
      gwr_v[NS-1:2] <= w_we[NS-1:2];
      // prefetch state
      if (pf_launch) begin
        pf_pend <= 1'b1;
        pf_slot <= Sm3;
        pf_lvl  <= lvl_of(Sm3);
        pf_word <= pf_tgt_loc_w[AWX-1:2];
        pf_lane <= pf_tgt_loc_w[1:0];
      end else if (pf_granted) begin
        pf_pend <= 1'b0;
      end
      // A grant and a new launch may coincide (back-to-back m==0 deletes):
      // the granted read keeps flowing through g0/g1 while the new target
      // takes over the pending slot.
      g0_v    <= pf_granted;
      g0_slot <= pf_slot; g0_lvl <= pf_lvl; g0_lane <= pf_lane;
      g1_v    <= g0_v;
      g1_slot <= g0_slot; g1_lvl <= g0_lvl; g1_lane <= g0_lane;
    end
  end

  // write record payload (no reset needed on data/addr)
  always @(posedge clk) begin
    gwr_a[1*IW +: IW]    <= 15'd1;
    gwr_d[1*ENT +: ENT]  <= root_nx;
    for (wk = 2; wk <= LEVELS; wk = wk + 1) begin
      gwr_a[wk*IW +: IW]   <= w_gaddr[wk*IW +: IW];
      gwr_d[wk*ENT +: ENT] <= w_data[wk*ENT +: ENT];
    end
  end

  // ---------------------------------------------------------------------
  // FF levels 2..4: storage writes
  // ---------------------------------------------------------------------
  always @(posedge clk) begin
    if (w_we[2]) ff2[w_addr[2*AWX +: 1]*ENT +: ENT] <= w_data[2*ENT +: ENT];
    if (w_we[3]) ff3[w_addr[3*AWX +: 2]*ENT +: ENT] <= w_data[3*ENT +: ENT];
    if (w_we[4]) ff4[w_addr[4*AWX +: 3]*ENT +: ENT] <= w_data[4*ENT +: ENT];
  end

  // ---------------------------------------------------------------------
  // Stages 2..LEVELS
  // ---------------------------------------------------------------------
  genvar L;
  generate
    for (L = 2; L <= LEVELS; L = L + 1) begin : g_st
      localparam LOCW = L - 1;              // local address width at level L

      // ---- op pipeline registers ----
      always @(posedge clk) begin
        if (rst) begin
          ins_v_r[L] <= 1'b0;
          del_v_r[L] <= 1'b0;
        end else begin
          ins_v_r[L] <= nx_ins_v[L-1];
          del_v_r[L] <= nx_del_v[L-1];
        end
        ins_w_r[L*ENT +: ENT] <= nx_ins_w[(L-1)*ENT +: ENT];
        ins_t_r[L*IW +: IW]   <= nx_ins_t[(L-1)*IW +: IW];
        ins_k_r[L*LW +: LW]   <= nx_ins_k[(L-1)*LW +: LW];
        del_w_r[L*ENT +: ENT] <= nx_del_w[(L-1)*ENT +: ENT];
        del_n_r[L*IW +: IW]   <= nx_del_n[(L-1)*IW +: IW];
        del_b_r[L*IW +: IW]   <= nx_del_b[(L-1)*IW +: IW];
      end

      // ---- INSERT compare at level L ----
      wire            ivr  = ins_v_r[L];
      wire [IW-1:0]   it   = ins_t_r[L*IW +: IW];
      wire [LW-1:0]   ik   = ins_k_r[L*LW +: LW];
      wire [ENT-1:0]  iw   = ins_w_r[L*ENT +: ENT];
      wire [IW-1:0]   pL   = it >> (ik - L);
      wire [LOCW-1:0] iloc = pL[LOCW-1:0];
      wire            landing = (ik == L);

      wire [ENT-1:0] res;   // resident path-node value
      if (L <= FF_TOP) begin : g_ires_ff
        if (L == 2)      assign res = ff2[iloc*ENT +: ENT];
        else if (L == 3) assign res = ff3[iloc*ENT +: ENT];
        else             assign res = ff4[iloc*ENT +: ENT];
      end else begin : g_ires_ram
        wire [ENT-1:0] raw = ram_do[(L*D2W + {10'b0,iloc[1:0]}*ENT) +: ENT];
        wire [AWX-1:0] la  = {{(AWX-LOCW){1'b0}}, iloc};
        assign res = (h0_v[L] && (h0_a[L*AWX +: AWX] == la)) ? h0_d[L*ENT +: ENT] :
                     (h1_v[L] && (h1_a[L*AWX +: AWX] == la)) ? h1_d[L*ENT +: ENT] :
                     raw;
      end

      wire wsm = iw[ENT-1:ID_W] < res[ENT-1:ID_W];  // tie -> resident stays
      wire iwe = ivr && !killed[L] && (landing || wsm);

      assign land_v[L]              = ivr && landing && !killed[L];
      assign nx_ins_v[L]            = ivr && !killed[L] && !landing;
      assign nx_ins_w[L*ENT +: ENT] = wsm ? res : iw;
      assign nx_ins_t[L*IW +: IW]   = it;
      assign nx_ins_k[L*LW +: LW]   = ik;

      // ---- DELETE compare at level L ----
      wire            dvr  = del_v_r[L];
      wire [ENT-1:0]  dv   = del_w_r[L*ENT +: ENT];
      wire [IW-1:0]   dn   = del_n_r[L*IW +: IW];
      wire [IW-1:0]   dbr  = del_b_r[L*IW +: IW];
      // same-cycle clamp: a delete issued THIS cycle must hide the slot it
      // is consuming from every in-flight sift (hazards H6/H7/H8). For the
      // occupancy checks the clamp is applied as a parallel second compare
      // (x <= min(a,b) == x<=a && x<=b) to keep the compare tree shallow;
      // the serial min only feeds the registered bound hand-off.
      wire [IW-1:0]   dbnd = (del_acc && (count_rm1 < dbr)) ? count_rm1 : dbr;
      wire [LOCW-1:0] dloc = dn[LOCW-1:0];

      wire settle, pick1;
      wire [ENT-1:0] dmin;
      wire [IW-1:0]  csel;

      if (L == LEVELS) begin : g_dbot
        // bottom level: no children, V always settles
        assign settle = 1'b1;
        assign pick1  = 1'b0;
        assign dmin   = dv;
        assign csel   = {IW{1'b0}};
      end else begin : g_dgen
        wire [IW-1:0] c0i = {dn[IW-2:0], 1'b0};
        wire [IW-1:0] c1i = {dn[IW-2:0], 1'b1};
        wire occ0 = (c0i <= dbr) && (!del_acc || (c0i <= count_rm1));
        wire occ1 = (c1i <= dbr) && (!del_acc || (c1i <= count_rm1));

        wire [ENT-1:0] c0v, c1v;
        if (L <= FF_TOP - 1) begin : g_dch_ff
          // children level L+1 <= 4: FF, combinational read
          wire [L-1:0] c0l = {dn[L-2:0], 1'b0};
          wire [L-1:0] c1l = {dn[L-2:0], 1'b1};
          if (L == 2) begin : g_c3
            assign c0v = ff3[c0l*ENT +: ENT];
            assign c1v = ff3[c1l*ENT +: ENT];
          end else begin : g_c4
            assign c0v = ff4[c0l*ENT +: ENT];
            assign c1v = ff4[c1l*ENT +: ENT];
          end
        end else begin : g_dch_ram
          // children level L+1 >= 5: lanes {2*dn[0], 2*dn[0]+1} of the
          // 4-wide data read via the grandchildren scheme, with the
          // depth-2 history bypass (paper's local bypasses).
          localparam CL = L + 1;
          wire [ENT-1:0] raw0 = ram_do[(CL*D2W + {12'b0,dn[0],1'b0}*ENT) +: ENT];
          wire [ENT-1:0] raw1 = ram_do[(CL*D2W + {12'b0,dn[0],1'b1}*ENT) +: ENT];
          wire [AWX-1:0] l0 = {{(AWX-(CL-1)){1'b0}}, ram_rw1[CL*WWX +: CL-3], dn[0], 1'b0};
          wire [AWX-1:0] l1 = {{(AWX-(CL-1)){1'b0}}, ram_rw1[CL*WWX +: CL-3], dn[0], 1'b1};
          assign c0v = (h0_v[CL] && (h0_a[CL*AWX +: AWX] == l0)) ? h0_d[CL*ENT +: ENT] :
                       (h1_v[CL] && (h1_a[CL*AWX +: AWX] == l0)) ? h1_d[CL*ENT +: ENT] :
                       raw0;
          assign c1v = (h0_v[CL] && (h0_a[CL*AWX +: AWX] == l1)) ? h0_d[CL*ENT +: ENT] :
                       (h1_v[CL] && (h1_a[CL*AWX +: AWX] == l1)) ? h1_d[CL*ENT +: ENT] :
                       raw1;
        end

        wire vle0 = dv[ENT-1:ID_W]  <= c0v[ENT-1:ID_W];
        wire vle1 = dv[ENT-1:ID_W]  <= c1v[ENT-1:ID_W];
        wire c01  = c0v[ENT-1:ID_W] <= c1v[ENT-1:ID_W];
        assign settle = !occ0 || (occ1 ? (vle0 && vle1) : vle0);
        assign pick1  = occ1 && !c01;
        assign dmin   = settle ? dv : (pick1 ? c1v : c0v);
        assign csel   = pick1 ? c1i : c0i;
      end

      assign b_dir[L] = pick1;
      assign nx_del_v[L]            = dvr && !settle;
      assign nx_del_w[L*ENT +: ENT] = dv;
      assign nx_del_n[L*IW +: IW]   = csel;
      assign nx_del_b[L*IW +: IW]   = dbnd;

      // ---- write port of level L (insert and delete are never resident
      //      at the same stage in the same cycle) ----
      wire dwe = dvr;
      assign w_we[L]              = dwe | iwe;
      assign w_addr[L*AWX +: AWX] = dwe ? {{(AWX-LOCW){1'b0}}, dloc}
                                        : {{(AWX-LOCW){1'b0}}, iloc};
      assign w_data[L*ENT +: ENT] = dwe ? dmin : iw;
      assign w_gaddr[L*IW +: IW]  = {{(IW-LOCW-1){1'b0}}, 1'b1,
                                     (dwe ? dloc : iloc)};
    end
  endgenerate

  // ---------------------------------------------------------------------
  // BRAM levels 5..LEVELS: 4 banks each, read arbitration, history
  // ---------------------------------------------------------------------
  genvar M, B;
  generate
    for (M = FF_TOP + 1; M <= LEVELS; M = M + 1) begin : g_ram
      localparam WW = M - 3;   // word-address width (bank depth 2^WW)

      // read requests:
      //  - delete comparing at stage M-3 this cycle (grandchildren read);
      //    address = {local(n at M-3), direction bit chosen this cycle}
      //  - live insert at stage M-2 whose path reaches level M
      //  - lastVal2 prefetch (lowest priority, retries until granted)
      wire rq_del = del_v_r[M-3];
      wire [WW-1:0] ad_del = {del_n_r[(M-3)*IW +: WW-1], b_dir[M-3]};
      wire [LW-1:0] ik2 = ins_k_r[(M-2)*LW +: LW];
      wire rq_ins = ins_v_r[M-2] && !killed[M-2] && (ik2 >= M);
      wire [IW-1:0] pM = ins_t_r[(M-2)*IW +: IW] >> (ik2 - M);
      wire [WW-1:0] ad_ins = pM[M-2:2];
      wire rq_pf = pf_pend && (pf_lvl == M);
      assign pf_gnt[M] = rq_pf && !rq_del && !rq_ins;

      wire [WW-1:0] ad = rq_del ? ad_del :
                         rq_ins ? ad_ins : pf_word[WW-1:0];
      assign ram_raddr[M*WWX +: WW] = ad;

      // write side: local address within level, bank = low 2 bits
      wire [WW-1:0] wa_word = w_addr[M*AWX+2 +: WW];
      wire [1:0]    wa_lane = w_addr[M*AWX +: 2];

      for (B = 0; B < 4; B = B + 1) begin : g_bank
        ram_dp #(.AW(WW), .DW(ENT)) u_bank (
          .clk   (clk),
          .we    (w_we[M] && (wa_lane == B)),
          .waddr (wa_word),
          .wdata (w_data[M*ENT +: ENT]),
          .raddr (ad),
          .dout2 (ram_do[(M*D2W + B*ENT) +: ENT])
        );
      end

      // word-address pipeline aligned with dout2
      reg [WW-1:0] rw0, rw1q;
      always @(posedge clk) begin
        rw0  <= ad;
        rw1q <= rw0;
      end
      assign ram_rw1[M*WWX +: WW] = rw1q;

      // depth-2 write history (local bypasses)
      reg        h0vq, h1vq;
      reg [AWX-1:0] h0aq, h1aq;
      reg [ENT-1:0] h0dq, h1dq;
      always @(posedge clk) begin
        if (rst) begin
          h0vq <= 1'b0; h1vq <= 1'b0;
        end else begin
          h0vq <= w_we[M];
          h1vq <= h0vq;
        end
        h0aq <= w_addr[M*AWX +: AWX];
        h0dq <= w_data[M*ENT +: ENT];
        h1aq <= h0aq;
        h1dq <= h0dq;
      end
      assign h0_v[M] = h0vq;
      assign h1_v[M] = h1vq;
      assign h0_a[M*AWX +: AWX] = h0aq;
      assign h1_a[M*AWX +: AWX] = h1aq;
      assign h0_d[M*ENT +: ENT] = h0dq;
      assign h1_d[M*ENT +: ENT] = h1dq;
    end
  endgenerate

  // tie off unused per-level buses (levels 0..4 have no RAM)
  generate
    for (M = 0; M <= FF_TOP; M = M + 1) begin : g_noram
      assign ram_do[M*D2W +: D2W]   = {D2W{1'b0}};
      assign ram_rw1[M*WWX +: WWX]  = {WWX{1'b0}};
      assign ram_raddr[M*WWX +: WWX]= {WWX{1'b0}};
      assign h0_v[M] = 1'b0;
      assign h1_v[M] = 1'b0;
      assign h0_a[M*AWX +: AWX] = {AWX{1'b0}};
      assign h1_a[M*AWX +: AWX] = {AWX{1'b0}};
      assign h0_d[M*ENT +: ENT] = {ENT{1'b0}};
      assign h1_d[M*ENT +: ENT] = {ENT{1'b0}};
      assign pf_gnt[M] = 1'b0;
    end
  endgenerate

endmodule

`default_nettype wire
