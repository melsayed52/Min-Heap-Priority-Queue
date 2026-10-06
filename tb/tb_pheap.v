// tb_pheap.v - self-checking testbench for the pipelined heap.
//
// Reference model: a plain software binary heap ordered by key only
// (multiset of keys), plus a per-ID table that maps each ID to the keys it
// currently carries. On every delete completion:
//   - the returned key must equal the reference model's minimum key, and
//   - the returned (key,id) pair must exist in the ID table (handles
//     duplicate keys correctly: any id carrying the minimum key is legal).
// Raw memory layouts are never compared (paper section V-C).
//
// Issue discipline: ops are only issued when the corresponding ready_* is
// high. The TB additionally *asserts* that ready_del is high whenever
// count>0 and the delete-after-delete bubble is not in force - i.e. the
// spec's issue rates are guaranteed by the DUT, not just followed by the TB.
//
// Plusargs: +seed=N  (random seed, printed; default 1)
//           +quick   (shortened random phases for smoke runs)
`timescale 1ns/1ps

module tb_pheap;

  localparam LEVELS = 14;
  localparam KEY_W  = 32;
  localparam ID_W   = 16;
  localparam ENT    = KEY_W + ID_W;
  localparam CAP    = (1 << LEVELS) - 1;   // 16383

  reg                clk;
  reg                rst;
  reg  [1:0]         op;
  reg  [KEY_W-1:0]   i_key;
  reg  [ID_W-1:0]    i_id;
  wire               ready_ins, ready_del;
  wire               del_valid;
  wire [KEY_W-1:0]   del_key;
  wire [ID_W-1:0]    del_id;
  wire [LEVELS:0]    count;
  wire               full, empty;

  pheap #(.LEVELS(LEVELS), .KEY_W(KEY_W), .ID_W(ID_W)) dut (
    .clk(clk), .rst(rst), .op(op), .ins_key(i_key), .ins_id(i_id),
    .ready_ins(ready_ins), .ready_del(ready_del),
    .del_valid(del_valid), .del_key(del_key), .del_id(del_id),
    .count(count), .full(full), .empty(empty)
  );

  initial clk = 1'b0;
  always #5 clk = ~clk;

  integer errors;
  integer seed;
  integer seed0;
  integer quick;
  integer total_ops;
  integer cyc_num;

  // ------------------------------------------------------------------
  // Reference model: keys-only binary heap
  // ------------------------------------------------------------------
  reg [ENT-1:0] rh [1:CAP+1];
  integer rn;

  task rpush;
    input [ENT-1:0] e;
    integer i;
    reg [ENT-1:0] t;
    begin
      rn = rn + 1;
      rh[rn] = e;
      i = rn;
      while (i > 1 && (rh[i>>1] >> ID_W) > (rh[i] >> ID_W)) begin
        t = rh[i>>1]; rh[i>>1] = rh[i]; rh[i] = t;
        i = i >> 1;
      end
    end
  endtask

  task rpop;
    output [ENT-1:0] e;
    integer i, c;
    reg [ENT-1:0] t;
    reg done;
    begin
      e = rh[1];
      rh[1] = rh[rn];
      rn = rn - 1;
      i = 1;
      done = 0;
      while (!done && (2*i <= rn)) begin
        c = 2*i;
        if (c + 1 <= rn && (rh[c+1] >> ID_W) < (rh[c] >> ID_W)) c = c + 1;
        if ((rh[i] >> ID_W) <= (rh[c] >> ID_W)) done = 1;
        else begin
          t = rh[i]; rh[i] = rh[c]; rh[c] = t;
          i = c;
        end
      end
    end
  endtask

  // ------------------------------------------------------------------
  // Per-ID key table: up to 8 simultaneous keys per id value
  // ------------------------------------------------------------------
  reg [KEY_W-1:0] idk  [0:(1<<ID_W)*8-1];
  reg             idkv [0:(1<<ID_W)*8-1];

  task id_add;
    input [ID_W-1:0]  id;
    input [KEY_W-1:0] k;
    integer j;
    reg done;
    begin
      done = 0;
      for (j = 0; j < 8; j = j + 1)
        if (!done && !idkv[id*8+j]) begin
          idkv[id*8+j] = 1'b1;
          idk[id*8+j]  = k;
          done = 1;
        end
      if (!done) begin
        errors = errors + 1;
        $display("TB-LIMIT: more than 8 live keys for id %0d @%0t", id, $time);
      end
    end
  endtask

  task id_remove;
    input [ID_W-1:0]  id;
    input [KEY_W-1:0] k;
    integer j;
    reg done;
    begin
      done = 0;
      for (j = 0; j < 8; j = j + 1)
        if (!done && idkv[id*8+j] && idk[id*8+j] == k) begin
          idkv[id*8+j] = 1'b0;
          done = 1;
        end
      if (!done) begin
        errors = errors + 1;
        $display("ERROR: delete returned (key=%0d,id=%0d) not live in reference @%0t",
                 k, id, $time);
      end
    end
  endtask

  // ------------------------------------------------------------------
  // Expected-delete FIFO (delete result appears 1 cycle after accept)
  // ------------------------------------------------------------------
  reg [KEY_W-1:0] expq [0:15];
  integer expq_wr, expq_rd;

  // ------------------------------------------------------------------
  // Result checking + protocol assertions, every cycle
  // ------------------------------------------------------------------
  reg bub_expect;   // mirrors DUT bubble: set the cycle after an accepted delete
  reg chk_en;       // checker enable, one cycle after reset release
  always @(posedge clk) begin
    cyc_num <= cyc_num + 1;
    chk_en  <= !rst;
    if (rst) bub_expect <= 1'b0;
    else     bub_expect <= (op == 2'b10) && ready_del;
  end

  always @(negedge clk) if (!rst && chk_en) begin
    // delete result check
    if (del_valid) begin
      if (expq_rd == expq_wr) begin
        errors = errors + 1;
        $display("ERROR: unexpected del_valid @%0t", $time);
      end else begin
        if (del_key !== expq[expq_rd & 15]) begin
          errors = errors + 1;
          $display("ERROR: del_key=%0d expected=%0d (op #%0d) @%0t",
                   del_key, expq[expq_rd & 15], expq_rd, $time);
        end
        id_remove(del_id, del_key);
        expq_rd = expq_rd + 1;
      end
    end
    // occupancy must track the reference exactly
    if (count !== rn[LEVELS:0]) begin
      errors = errors + 1;
      $display("ERROR: count=%0d ref=%0d @%0t", count, rn, $time);
    end
    // spec issue-rate guarantees: ready_del low only when empty or bubble;
    // ready_ins low only when full
    if (!ready_del && count != 0 && !bub_expect) begin
      errors = errors + 1;
      $display("ERROR: ready_del low with count=%0d, no bubble @%0t (throughput spec violation)",
               count, $time);
    end
    if (!ready_ins && !full) begin
      errors = errors + 1;
      $display("ERROR: ready_ins low while not full @%0t", $time);
    end
    if (ready_del && count == 0) begin
      errors = errors + 1;
      $display("ERROR: ready_del high while empty @%0t", $time);
    end
    if (ready_ins && full) begin
      errors = errors + 1;
      $display("ERROR: ready_ins high while full @%0t", $time);
    end
    // internal sanity: an insert and a delete must never share a stage
    if ((dut.ins_v_r & dut.del_v_r) != 0) begin
      errors = errors + 1;
      $display("ERROR: insert and delete resident at same stage @%0t", $time);
    end
    if (errors > 25) begin
      $display("FAIL: too many errors, aborting @%0t", $time);
      $finish;
    end
  end

  // ------------------------------------------------------------------
  // Cycle driver: call right after a negedge; issues one op
  // ------------------------------------------------------------------
  reg [ENT-1:0] rtmp;

  task cyc;
    input [1:0]       o;
    input [KEY_W-1:0] k;
    input [ID_W-1:0]  id;
    begin
      op = o; i_key = k; i_id = id;
      if (o == 2'b01) begin
        if (!ready_ins) begin
          errors = errors + 1;
          $display("TB-BUG: insert issued while not ready @%0t", $time);
        end else begin
          rpush({k, id});
          id_add(id, k);
          total_ops = total_ops + 1;
        end
      end else if (o == 2'b10) begin
        if (!ready_del) begin
          errors = errors + 1;
          $display("TB-BUG: delete issued while not ready @%0t", $time);
        end else begin
          rpop(rtmp);
          expq[expq_wr & 15] = rtmp >> ID_W;
          expq_wr = expq_wr + 1;
          total_ops = total_ops + 1;
        end
      end
      @(negedge clk);
      op = 2'b00;
    end
  endtask

  task cnop; begin cyc(2'b00, 0, 0); end endtask

  // rolling id generator
  reg [ID_W-1:0] next_id;
  task cins;
    input [KEY_W-1:0] k;
    begin
      cyc(2'b01, k, next_id);
      next_id = next_id + 1;
    end
  endtask

  task cdel; begin cyc(2'b10, 0, 0); end endtask

  // wait for pipeline to fully settle (all in-flight ops land)
  task settle;
    integer i;
    begin
      for (i = 0; i < 2*LEVELS + 8; i = i + 1) cnop;
    end
  endtask

  // ------------------------------------------------------------------
  // Directed tests
  // ------------------------------------------------------------------
  integer ti, tj, tg;
  integer start_errs;

  task t_banner;
    input [8*40-1:0] name;
    begin
      start_errs = errors;
      $display("[%0t] TEST: %0s", $time, name);
    end
  endtask

  // drain everything at max legal rate, checking every result
  task drain_all;
    begin
      while (rn > 0) begin
        if (ready_del) cdel;
        else cnop;
      end
      settle;
    end
  endtask

  task t_smoke;
    begin
      t_banner("smoke: single insert/delete");
      cins(32'd100);
      settle;
      cdel;
      settle;

      t_banner("smoke: fill-drain 50, ascending keys");
      for (ti = 0; ti < 50; ti = ti + 1) cins(ti);
      settle;
      drain_all;

      t_banner("smoke: fill-drain 50, descending keys");
      for (ti = 0; ti < 50; ti = ti + 1) cins(1000 - ti);
      settle;
      drain_all;

      t_banner("smoke: duplicate keys and extremes");
      for (ti = 0; ti < 40; ti = ti + 1) cins(32'd7);
      cins(32'h0);
      cins(32'hFFFFFFFF);
      cins(32'h0);
      cins(32'hFFFFFFFF);
      for (ti = 0; ti < 20; ti = ti + 1) cins(32'd7);
      settle;
      drain_all;

      t_banner("smoke: interleaved I/D no gaps");
      for (ti = 0; ti < 200; ti = ti + 1) begin
        cins($random(seed));
        if (ready_del) cdel;
      end
      drain_all;
    end
  endtask

  task t_ready_rules;
    begin
      t_banner("ready rules: empty/bubble/full");
      // empty
      if (ready_del) begin errors = errors + 1; $display("ERROR: ready_del on empty"); end
      cins(32'd5);
      cins(32'd6);
      cins(32'd7);
      // bubble after delete
      cdel;
      if (ready_del) begin errors = errors + 1; $display("ERROR: no bubble after delete"); end
      cnop;
      if (!ready_del) begin errors = errors + 1; $display("ERROR: bubble longer than 1 cycle"); end
      cdel;
      cnop;
      cdel;
      settle;
    end
  endtask

  task t_fill_full;
    begin
      t_banner("fill to full (16383), verify full, drain all");
      while (rn < CAP) cins($random(seed));
      settle;
      if (!full) begin errors = errors + 1; $display("ERROR: full not asserted"); end
      if (ready_ins) begin errors = errors + 1; $display("ERROR: ready_ins at full"); end
      // delete a couple, reinsert, then drain everything
      cdel; cnop; cdel; cnop;
      cins(32'd0);
      cins(32'hFFFFFFFF);
      settle;
      drain_all;
      if (!empty) begin errors = errors + 1; $display("ERROR: empty not asserted"); end
    end
  endtask

  task t_hz_chases;
    begin
      t_banner("hazard: I-I chase, descending back-to-back");
      for (ti = 0; ti < 300; ti = ti + 1) cins(32'd100000 - ti);
      settle;
      t_banner("hazard: I-I chase, ascending back-to-back");
      for (ti = 0; ti < 300; ti = ti + 1) cins(32'd200000 + ti);
      settle;
      t_banner("hazard: D-bubble-D chase (Fig.6 pattern) and D-I chase");
      // delete streams at max rate over a heap arranged by prior inserts
      for (ti = 0; ti < 200; ti = ti + 1) begin
        if (ready_del) cdel; else cnop;
      end
      // D-I-D-I: delete every other cycle with inserts between (aborts!)
      for (ti = 0; ti < 200; ti = ti + 1) begin
        if (ready_del) cdel;
        cins(32'd150000 + (ti * 37) % 1000);
      end
      drain_all;
    end
  endtask

  task t_hz_abort_depths;
    begin
      t_banner("hazard: insert-abort at every depth (gap sweep)");
      // deep heap so inserts have long paths
      while (rn < 9000) cins($random(seed));
      settle;
      for (tg = 0; tg <= 2*LEVELS; tg = tg + 1) begin
        // insert then delete after tg idle cycles: aborts insert at depth tg+1
        cins(32'd42 + tg);
        for (tj = 0; tj < tg; tj = tj + 1) cnop;
        cdel;
        cnop;
      end
      // insert chains then a delete: youngest of several gets aborted
      for (tg = 1; tg <= 8; tg = tg + 1) begin
        for (tj = 0; tj < tg; tj = tj + 1) cins($random(seed));
        cdel;
        cnop;
      end
      settle;
      drain_all;
    end
  endtask

  task t_hz_drain_chains;
    begin
      t_banner("hazard: m=0 delete chains across level boundaries");
      // park occupancy just above each power of two, then drain through the
      // boundary at max rate (exercises lastVal2 prefetch + retries)
      for (tg = 4; tg <= LEVELS; tg = tg + 1) begin
        while (rn < (1 << tg) + 6 && rn < CAP) cins($random(seed));
        settle;
        for (tj = 0; tj < 14; tj = tj + 1) begin
          if (ready_del) cdel; else cnop;
        end
        settle;
      end
      drain_all;

      t_banner("hazard: steal/late-write races, constant keys");
      // equal keys everywhere -> ties, shallow settles, sifts that terminate
      // early while deletes chain behind them
      for (ti = 0; ti < 600; ti = ti + 1) cins(32'd99);
      settle;
      for (ti = 0; ti < 100; ti = ti + 1) begin
        if (ready_del) cdel; else cnop;
      end
      for (ti = 0; ti < 100; ti = ti + 1) begin
        cins(32'd99);
        if (ready_del) cdel;
      end
      drain_all;

      t_banner("hazard: landing exactly at delete (gap = depth-1)");
      // near-boundary occupancies with gap tuned so the insert lands the
      // same cycle the delete issues
      for (tg = 5; tg <= LEVELS; tg = tg + 1) begin
        while (rn < (1 << (tg-1)) + 2) cins($random(seed));
        while (rn > (1 << (tg-1)) + 2) begin
          if (ready_del) cdel; else cnop;
        end
        settle;
        cins(32'hF0000000);            // large key: travels all the way down
        for (tj = 0; tj < tg - 1; tj = tj + 1) cnop;
        cdel;                          // issue as/after the insert lands
        cnop;
        settle;
      end
      drain_all;
    end
  endtask

  // ------------------------------------------------------------------
  // Random phases
  // ------------------------------------------------------------------
  integer ph_cycles, ph_ins, ph_del;
  integer r;

  task rnd_phase;
    input integer n_ops;         // approximate op budget
    input integer w_ins;         // out of 100
    input integer w_del;         // out of 100 (rest = nop)
    input integer narrow;        // 1 = narrow key range (duplicates)
    integer done_ops;
    reg [31:0] kk;
    begin
      done_ops = 0;
      ph_cycles = 0; ph_ins = 0; ph_del = 0;
      while (done_ops < n_ops) begin
        r = $unsigned($random(seed)) % 100;
        kk = narrow ? ($unsigned($random(seed)) % 16)
                    : $random(seed);
        if (r < w_ins && ready_ins) begin
          cins(kk);
          ph_ins = ph_ins + 1;
          done_ops = done_ops + 1;
        end else if (r < w_ins + w_del && ready_del) begin
          cdel;
          ph_del = ph_del + 1;
          done_ops = done_ops + 1;
        end else begin
          cnop;
        end
        ph_cycles = ph_cycles + 1;
      end
    end
  endtask

  // saturation throughput measurements
  integer m_cycles, m_ops;
  real rate_ins, rate_mix, rate_del;

  task t_throughput;
    begin
      t_banner("throughput: sustained insert (1/cycle)");
      drain_all;
      // warm up a base heap
      for (ti = 0; ti < 100; ti = ti + 1) cins($random(seed));
      settle;
      m_cycles = 0; m_ops = 0;
      while (rn < 10100 && ready_ins) begin
        cins($random(seed));
        m_ops = m_ops + 1;
        m_cycles = m_cycles + 1;
      end
      rate_ins = (1.0 * m_ops) / m_cycles;
      $display("  insert-saturation: %0d ops / %0d cycles = %f ops/cycle",
               m_ops, m_cycles, rate_ins);

      t_banner("throughput: alternating delete/insert (1 op/cycle)");
      m_cycles = 0; m_ops = 0;
      for (ti = 0; ti < 5000; ti = ti + 1) begin
        if (ready_del) begin cdel; m_ops = m_ops + 1; end
        else begin errors = errors + 1; $display("ERROR: stall in D/I alternation"); cnop; end
        m_cycles = m_cycles + 1;
        if (ready_ins) begin cins($random(seed)); m_ops = m_ops + 1; end
        else begin errors = errors + 1; $display("ERROR: stall in D/I alternation"); cnop; end
        m_cycles = m_cycles + 1;
      end
      rate_mix = (1.0 * m_ops) / m_cycles;
      $display("  delete/insert alternation: %0d ops / %0d cycles = %f ops/cycle",
               m_ops, m_cycles, rate_mix);

      t_banner("throughput: sustained delete drain (0.5/cycle)");
      m_cycles = 0; m_ops = 0;
      while (rn > 100) begin
        if (ready_del) begin cdel; m_ops = m_ops + 1; end
        else cnop;
        m_cycles = m_cycles + 1;
      end
      rate_del = (1.0 * m_ops) / m_cycles;
      $display("  delete-saturation: %0d ops / %0d cycles = %f ops/cycle",
               m_ops, m_cycles, rate_del);

      if (rate_ins < 0.999) begin
        errors = errors + 1;
        $display("ERROR: insert throughput %f < 1.0/cycle", rate_ins);
      end
      if (rate_mix < 0.999) begin
        errors = errors + 1;
        $display("ERROR: alternation throughput %f < 1.0/cycle", rate_mix);
      end
      if (rate_del < 0.499) begin
        errors = errors + 1;
        $display("ERROR: delete throughput %f < 0.5/cycle", rate_del);
      end
      drain_all;
    end
  endtask

  // ------------------------------------------------------------------
  // Main
  // ------------------------------------------------------------------
  integer i;
  integer rnd_budget;

  initial begin
    errors = 0; total_ops = 0; cyc_num = 0;
    rn = 0; expq_wr = 0; expq_rd = 0; next_id = 0;
    op = 2'b00; i_key = 0; i_id = 0;
    seed = 1;
    if ($value$plusargs("seed=%d", seed)) ;
    seed0 = seed;
    quick = $test$plusargs("quick");
    $display("=== tb_pheap: seed=%0d quick=%0d ===", seed, quick);
    for (i = 0; i < (1<<ID_W)*8; i = i + 1) idkv[i] = 1'b0;

    rst = 1'b1;
    repeat (5) @(negedge clk);
    rst = 1'b0;
    @(negedge clk);

    // ---- directed suite ----
    t_smoke;
    t_ready_rules;
    t_hz_chases;
    t_hz_abort_depths;
    t_hz_drain_chains;
    if (!quick) t_fill_full;

    // ---- randomized regression ----
    rnd_budget = quick ? 20000 : 200000;
    $display("[%0t] RANDOM: insert-heavy (70/20)", $time);
    rnd_phase(rnd_budget, 70, 20, 0);
    $display("  phase: %0d ins %0d del in %0d cycles", ph_ins, ph_del, ph_cycles);
    $display("[%0t] RANDOM: balanced (45/45)", $time);
    rnd_phase(quick ? 30000 : 300000, 45, 45, 0);
    $display("  phase: %0d ins %0d del in %0d cycles", ph_ins, ph_del, ph_cycles);
    $display("[%0t] RANDOM: delete-heavy (25/65)", $time);
    rnd_phase(rnd_budget, 25, 65, 0);
    $display("  phase: %0d ins %0d del in %0d cycles", ph_ins, ph_del, ph_cycles);
    $display("[%0t] RANDOM: narrow keys, balanced (45/45)", $time);
    rnd_phase(rnd_budget, 45, 45, 1);
    $display("  phase: %0d ins %0d del in %0d cycles", ph_ins, ph_del, ph_cycles);
    drain_all;

    // ---- throughput measurement (also ~60k ops) ----
    t_throughput;

    // ---- final ----
    settle;
    $display("=============================================");
    $display(" total ops checked : %0d", total_ops);
    $display(" total cycles      : %0d", cyc_num);
    $display(" errors            : %0d", errors);
    if (errors == 0) $display(" RESULT: PASS (seed=%0d)", seed0);
    else             $display(" RESULT: FAIL (seed=%0d)", seed0);
    $display("=============================================");
    $finish;
  end

endmodule
