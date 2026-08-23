// The reference 4x4 mesh, driven at every device port.
//
// This is the first testbench with a network in it. `chi_xp_channel_tb` proves
// one switch moves flits correctly; this one asks the questions that only exist
// once switches are wired to each other -- does every device reach every other
// device, does the thing drain when the traffic stops, and how fast does it go.
//
// The mesh is generated: `//hardware/ip/chi_noc:mesh4x4`, from the topology in
// nocgen/examples/mesh4x4.yml, whose NodeIDs and expected numbers are in
// //hardware/ip/chi_noc/README.md and in the generated package this reads them
// from. Nothing here is written down twice.
//
// **REQ only, for everything except the `all_classes` case.** At mesh level the
// four channel classes are four disjoint netlists that share a clock; `chi_xp_test`
// already shows they do not interact inside a crosspoint, so driving all four
// through the mesh would multiply the simulation cost without exercising a new
// mechanism. What `all_classes` is for is the one thing that *could* differ in a
// generated mesh -- a class miswired in the netlist rather than in the RTL.
//
// One model, several cases: `+case=` picks which. See BUILD.bazel.
module chi_noc_mesh_tb #(
    parameter time ClkHalfPeriod = 1ns,
    // Matches the fabric's: a device link with fewer credits than the
    // crosspoints have would be the bottleneck, and would be measuring the
    // testbench rather than the mesh.
    parameter int unsigned Credits = 6,

    // Flits per source for the throughput and pattern cases. Enough that the
    // measurement is of steady state rather than of filling the pipes.
    parameter int unsigned BurstFlits = 256,

    parameter int unsigned Timeout = 400000
);

  import chi_noc_pkg::*;
  import chi_noc_flit_pkg::*;
  import mesh4x4_noc_pkg::*;

  localparam int unsigned Devices = NumDevices;

  ////////////////////////////////////////////////////////////////////////////////////////////////
  // Clock, reset, case
  ////////////////////////////////////////////////////////////////////////////////////////////////

  logic clk;
  logic rst_n;

  initial begin
    clk = 1'b0;
    forever #ClkHalfPeriod clk = ~clk;
  end

  initial begin
    rst_n = 1'b0;
    repeat (4) @(negedge clk);
    rst_n = 1'b1;
  end

  string test_case;

  initial begin
    if (!$value$plusargs("case=%s", test_case))
      $fatal(1, "no +case= given; see BUILD.bazel for the cases this testbench has");
  end

  int unsigned cycle;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) cycle <= 0;
    else cycle <= cycle + 1;
  end

  ////////////////////////////////////////////////////////////////////////////////////////////////
  // The mesh, and a link partner on every device port
  ////////////////////////////////////////////////////////////////////////////////////////////////

  chi_xp_port_t [Devices-1:0] dev_rx;
  chi_xp_port_t [Devices-1:0] dev_tx;

  mesh4x4_noc i_dut (
      .clk_i (clk),
      .rst_ni(rst_n),
      .dev_rx_i(dev_rx),
      .dev_tx_o(dev_tx)
  );

  // The same shape per class, so it is written once. See chi_xp_tb for why a
  // macro rather than four copies: the difference between the classes is
  // exactly what a copy would get wrong.
`define CHI_NOC_TB_PARTNER(__name, __width, __member)                                             \
  logic                 __name``_inject_valid[Devices];                                           \
  logic                 __name``_inject_ready[Devices];                                           \
  logic [__width-1:0]   __name``_inject_flit [Devices];                                           \
  logic [Devices-1:0]              __name``_eject_valid;                                          \
  logic [Devices-1:0]              __name``_eject_ready;                                          \
  logic [Devices-1:0][__width-1:0] __name``_eject_flit;                                           \
                                                                                                  \
  for (genvar d = 0; d < Devices; d++) begin : gen_``__name``_partner                             \
    chi_link_tx_channel #(                                                                        \
        .FlitWidth(__width)                                                                       \
    ) i_inject (                                                                                  \
        .clk_i     (clk),                                                                         \
        .rst_ni    (rst_n),                                                                       \
        .state_i   (chi_pkg::CHI_LINK_RUN),                                                       \
        .flit_i    (__name``_inject_flit[d]),                                                     \
        .valid_i   (__name``_inject_valid[d]),                                                    \
        .ready_o   (__name``_inject_ready[d]),                                                    \
        .flitpend_o(dev_rx[d].__member.flitpend),                                                 \
        .flitv_o   (dev_rx[d].__member.flitv),                                                    \
        .flit_o    (dev_rx[d].__member.flit),                                                     \
        .lcrdv_i   (dev_tx[d].__member``_lcrdv),                                                  \
        .credits_o ()                                                                             \
    );                                                                                            \
                                                                                                  \
    chi_link_rx_channel #(                                                                        \
        .FlitWidth(__width),                                                                      \
        .Credits  (Credits)                                                                       \
    ) i_eject (                                                                                   \
        .clk_i           (clk),                                                                   \
        .rst_ni          (rst_n),                                                                 \
        .state_i         (chi_pkg::CHI_LINK_RUN),                                                 \
        .flitpend_i      (dev_tx[d].__member.flitpend),                                           \
        .flitv_i         (dev_tx[d].__member.flitv),                                              \
        .flit_i          (dev_tx[d].__member.flit),                                               \
        .is_lcrd_return_i(dev_tx[d].__member.flitv && (dev_tx[d].__member.flit == '0)),           \
        .lcrdv_o         (dev_rx[d].__member``_lcrdv),                                            \
        .flit_o          (__name``_eject_flit[d]),                                                \
        .valid_o         (__name``_eject_valid[d]),                                               \
        .ready_i         (__name``_eject_ready[d]),                                               \
        .outstanding_o   ()                                                                       \
    );                                                                                            \
  end

  `CHI_NOC_TB_PARTNER(req, CHI_XP_REQ_WIDTH, req)
  `CHI_NOC_TB_PARTNER(rsp, CHI_XP_RSP_WIDTH, rsp)
  `CHI_NOC_TB_PARTNER(dat, CHI_XP_DAT_WIDTH, dat)
  `CHI_NOC_TB_PARTNER(snp, CHI_XP_SNP_WIDTH, snp)

`undef CHI_NOC_TB_PARTNER

  ////////////////////////////////////////////////////////////////////////////////////////////////
  // Which device is where
  ////////////////////////////////////////////////////////////////////////////////////////////////

  function automatic int unsigned device_at(chi_noc_x_t x, chi_noc_y_t y);
    for (int unsigned d = 0; d < Devices; d++) begin
      if (chi_noc_node_x(DeviceNodeId[d]) == x && chi_noc_node_y(DeviceNodeId[d]) == y) return d;
    end
    return 0;
  endfunction

  function automatic int unsigned hops_between(int unsigned src, int unsigned dst);
    automatic int sx = int'(chi_noc_node_x(DeviceNodeId[src]));
    automatic int sy = int'(chi_noc_node_y(DeviceNodeId[src]));
    automatic int dx = int'(chi_noc_node_x(DeviceNodeId[dst]));
    automatic int dy = int'(chi_noc_node_y(DeviceNodeId[dst]));
    return unsigned'(((dx > sx) ? dx - sx : sx - dx) + ((dy > sy) ? dy - sy : sy - dy));
  endfunction

  ////////////////////////////////////////////////////////////////////////////////////////////////
  // Traffic patterns
  //
  // Each maps a source to a destination. Uniform is the one every published
  // mesh number is quoted for; the other three are the ones that find what
  // uniform hides -- a hot link, a hot output, or a routing scheme that only
  // spreads load when the load happens to be spread.
  ////////////////////////////////////////////////////////////////////////////////////////////////

  typedef enum int unsigned {
    PatternUniform,
    PatternTranspose,
    PatternComplement,
    PatternHotspot,
    PatternNeighbour
  } pattern_e;

  pattern_e pattern;
  int unsigned hotspot_target;

  ////////////////////////////////////////////////////////////////////////////////////////////////
  // What each pattern should manage, in parts per thousand
  //
  // These are **measured**, less a margin -- they are a ratchet against
  // regression and not a specification. Raising one when the design improves is
  // the point of having them; a floor nobody can move is a floor nobody set
  // deliberately.
  //
  // The margin is wider for uniform because its destinations are drawn at
  // random and the other three are fixed, so only uniform varies run to run.
  //
  // What limits each is not the same thing, which is why they differ so much:
  // uniform and complement spread over the whole mesh and are limited by
  // head-of-line blocking at the inputs; transpose concentrates traffic on the
  // diagonal's links; hotspot is limited by one destination port and nothing
  // else, so its ceiling is one flit per cycle shared sixteen ways.
  ////////////////////////////////////////////////////////////////////////////////////////////////

  localparam int unsigned FloorUniform = 560;  // measured 603
  localparam int unsigned FloorTranspose = 270;  // measured 286
  localparam int unsigned FloorComplement = 470;  // measured 500
  localparam int unsigned FloorHotspot = 60;  // measured 66, against a ceiling of 125
  localparam int unsigned FloorNeighbour = 950;  // measured 1000 -- line rate

  // The simulator's $urandom is per-process, which is what we want here:
  // sixteen injectors picking independently.
  // No device ever addresses itself. That is not a per-pattern detail: a NodeID
  // is a device, so a flit addressed to its own source is a node talking to
  // itself, which `chi_xp_channel` asserts on and is right to. Two of the four
  // patterns produce it naturally -- transpose fixes every device on the
  // diagonal, and hotspot makes the target one of the sources -- so the guard
  // belongs here rather than in each of them.
  function automatic int unsigned destination(int unsigned src);
    automatic int unsigned d;
    d = raw_destination(src);
    return (d == src) ? (src + 1) % Devices : d;
  endfunction

  function automatic int unsigned raw_destination(int unsigned src);
    automatic int unsigned d;
    case (pattern)
      PatternTranspose: begin
        // (x, y) -> (y, x). The reference topology has one device per
        // crosspoint, so every transpose lands on a real device.
        return device_at(chi_noc_x_t'(chi_noc_node_y(DeviceNodeId[src])),
                         chi_noc_y_t'(chi_noc_node_x(DeviceNodeId[src])));
      end
      PatternNeighbour: begin
        // One hop east, wrapping within the row. A permutation, so every input
        // has exactly one destination and every output exactly one source:
        // head-of-line blocking is impossible by construction and no link
        // carries more than one stream. The control for the throughput
        // measurements -- whatever this reaches is what the fabric can do when
        // nothing is in anything else's way.
        return device_at(chi_noc_x_t'((chi_noc_node_x(DeviceNodeId[src]) + 1) % 4),
                         chi_noc_y_t'(chi_noc_node_y(DeviceNodeId[src])));
      end
      PatternComplement: return Devices - 1 - src;
      PatternHotspot:    return hotspot_target;
      default: begin
        // Uniform over everything but itself: a device addressing its own
        // NodeID is the `self` case in chi_xp_channel_tb, not traffic.
        d = $urandom_range(Devices - 2, 0);
        return (d >= src) ? d + 1 : d;
      end
    endcase
  endfunction

  ////////////////////////////////////////////////////////////////////////////////////////////////
  // The scoreboard
  //
  // Per-pair sequence counters rather than queues: order is promised per
  // (source, destination) and an integer compare says whether it held. See
  // tasks/lessons.md for why not queues.
  ////////////////////////////////////////////////////////////////////////////////////////////////

  localparam int unsigned Pairs = Devices * Devices;

  function automatic int unsigned pair(int unsigned src, int unsigned dst);
    return src * Devices + dst;
  endfunction

  int unsigned next_seq[Pairs];  // written by the injectors
  int unsigned want_seq[Pairs];  // read and written by the scoreboard

  int unsigned sent_count;
  int unsigned received_count;

  // Latency, in cycles, from the flit leaving its source to arriving at its
  // destination. Summed rather than histogrammed: the mean is what the analytic
  // number is, and the minimum is what the zero-load number is.
  int unsigned latency_sum;
  int unsigned latency_min;
  int unsigned latency_max;

  // Set by a case that wants to see the mesh refuse to drain.
  logic [Devices-1:0] eject_stall;

  for (genvar d = 0; d < Devices; d++) begin : gen_ready
    assign req_eject_ready[d] = !eject_stall[d];
    assign rsp_eject_ready[d] = 1'b1;
    assign dat_eject_ready[d] = 1'b1;
    assign snp_eject_ready[d] = 1'b1;
  end

  chi_pkg::chi_req_t seen_flit;
  int unsigned seen_src;
  int unsigned seen_seq;
  int unsigned seen_pair;
  int unsigned seen_now;
  int unsigned seen_latency;

  // Which device a NodeID belongs to, for turning a flit's SrcID back into an
  // index. A loop rather than a table because it runs once per arrival and the
  // table would be another thing to keep in step.
  function automatic int unsigned device_of(chi_noc_nodeid_t node_id);
    for (int unsigned d = 0; d < Devices; d++) if (DeviceNodeId[d] == node_id) return d;
    return Devices;  // no such device; the caller fails on it
  endfunction

  always_ff @(posedge clk) begin
    if (rst_n) begin
      seen_now = 0;
      for (int unsigned d = 0; d < Devices; d++) begin
        if (req_eject_valid[d] && req_eject_ready[d]) begin
          seen_flit = req_eject_flit[d];
          seen_src  = device_of(seen_flit.src_id);
          seen_seq  = {20'd0, seen_flit.txn_id};

          if (seen_src >= Devices) begin
            $fatal(1, "device %0d: flit with SrcID %03h, which is no device", d, seen_flit.src_id);
          end
          if (seen_flit.tgt_id != DeviceNodeId[d]) begin
            $fatal(1, "device %0d: flit addressed to %03h arrived here (%03h)", d,
                   seen_flit.tgt_id, DeviceNodeId[d]);
          end

          seen_pair = pair(seen_src, d);
          if (seen_seq != want_seq[seen_pair]) begin
            $fatal(1, "device %0d: from %0d out of order -- got seq %0d, wanted %0d", d, seen_src,
                   seen_seq, want_seq[seen_pair]);
          end
          want_seq[seen_pair] = want_seq[seen_pair] + 1;

          // The injection cycle rides in the address field, so latency needs no
          // bookkeeping outside the flit and survives any amount of reordering
          // between pairs.
          seen_latency = cycle - {{(48 - 32) {1'b0}}, seen_flit.addr}[31:0];
          latency_sum  = latency_sum + seen_latency;
          if (seen_latency < latency_min) latency_min = seen_latency;
          if (seen_latency > latency_max) latency_max = seen_latency;

          seen_now = seen_now + 1;
        end
      end
      received_count = received_count + seen_now;
    end
  end

  ////////////////////////////////////////////////////////////////////////////////////////////////
  // The injectors
  //
  // One process per device, so sixteen sources really do contend. Each owns its
  // own row of the expectation and nothing is shared between them.
  ////////////////////////////////////////////////////////////////////////////////////////////////

  int unsigned inj_remaining[Devices];
  int unsigned inj_dst      [Devices];
  logic        inj_fixed_dst[Devices];  // set by cases that name the destination

  chi_pkg::chi_req_t built;

  for (genvar d = 0; d < Devices; d++) begin : gen_injector
    initial begin
      req_inject_valid[d] = 1'b0;
      req_inject_flit[d]  = '0;
      inj_remaining[d] = 0;
      inj_dst[d] = 0;
      inj_fixed_dst[d] = 1'b0;

      forever begin
        @(negedge clk);
        if (!rst_n) begin
          req_inject_valid[d] = 1'b0;
        end else if (inj_remaining[d] != 0) begin
          automatic int unsigned dst = inj_fixed_dst[d] ? inj_dst[d] : destination(d);
          // A new destination each time only when the pattern says so; holding
          // it otherwise is what makes per-pair ordering meaningful.
          if (!inj_fixed_dst[d]) inj_dst[d] = dst;

          built = '0;
          // Opcode zero is an L-Credit return on every channel, so a flit built
          // out of zeroes is flow control and never arrives. See the README.
          built.opcode = chi_pkg::CHI_REQ_READ_NO_SNP;
          built.qos    = 4'h8;
          built.tgt_id = DeviceNodeId[inj_dst[d]];
          built.src_id = DeviceNodeId[d];
          built.txn_id = 12'(next_seq[pair(d, inj_dst[d])]);
          built.addr   = 48'(cycle);

          req_inject_flit[d]  = built;
          req_inject_valid[d] = 1'b1;

          if (req_inject_ready[d]) begin
            next_seq[pair(d, inj_dst[d])] = next_seq[pair(d, inj_dst[d])] + 1;
            inj_remaining[d]--;
            sent_count++;
          end
        end else begin
          req_inject_valid[d] = 1'b0;
        end
      end
    end
  end

  task automatic run_all(input int unsigned count);
    for (int unsigned d = 0; d < Devices; d++) inj_remaining[d] = count;
    for (int unsigned d = 0; d < Devices; d++) begin
      while (inj_remaining[d] != 0) @(posedge clk);
    end
  endtask

  task automatic drain(input int unsigned quiet_cycles = 400);
    int unsigned idle;
    idle = 0;
    while (idle < quiet_cycles) begin
      @(posedge clk);
      if (received_count == sent_count) idle++;
      else idle = 0;
    end
  endtask

  function automatic void expect_all_delivered();
    if (received_count != sent_count) begin
      $fatal(1, "sent %0d flits and %0d arrived", sent_count, received_count);
    end
    for (int unsigned s = 0; s < Devices; s++) begin
      for (int unsigned t = 0; t < Devices; t++) begin
        if (next_seq[pair(s, t)] != want_seq[pair(s, t)]) begin
          $fatal(1, "%0d flits from device %0d to device %0d never arrived",
                 next_seq[pair(s, t)] - want_seq[pair(s, t)], s, t);
        end
      end
    end
  endfunction

  // How many device ports the current pattern actually aims at. Aggregate
  // ejection cannot exceed one flit per cycle per distinct destination.
  function automatic int unsigned distinct_destinations();
    logic [Devices-1:0] hit;
    int unsigned count;
    // Uniform draws afresh every flit, so every device is a destination.
    if (pattern == PatternUniform) return Devices;
    hit = '0;
    for (int unsigned s = 0; s < Devices; s++) hit[destination(s)] = 1'b1;
    count = 0;
    for (int unsigned d = 0; d < Devices; d++) if (hit[d]) count++;
    return count;
  endfunction

  // Throughput as flits per cycle per device, in parts per thousand, so it can
  // be compared against the generated bound without a real number in sight.
  function automatic int unsigned throughput_per_mille(input int unsigned flits,
                                                       input int unsigned cycles);
    if (cycles == 0) return 0;
    return (flits * 1000) / (cycles * Devices);
  endfunction

  ////////////////////////////////////////////////////////////////////////////////////////////////
  // The cases
  ////////////////////////////////////////////////////////////////////////////////////////////////

  int unsigned started;
  int unsigned elapsed;
  int unsigned measured;
  int unsigned ceiling;
  int unsigned floor;

  initial begin
    eject_stall = '0;
    sent_count = 0;
    received_count = 0;
    latency_sum = 0;
    latency_min = 32'hffff_ffff;
    latency_max = 0;
    pattern = PatternUniform;
    hotspot_target = HNF0_INDEX;
    for (int unsigned i = 0; i < Pairs; i++) begin
      next_seq[i] = 0;
      want_seq[i] = 0;
    end

    wait (rst_n);
    repeat (8) @(posedge clk);

    case (test_case)

      // Every ordered pair of devices, one flit each, with the mesh emptied
      // between rounds. 240 pairs: if every device can reach every other one,
      // the generated netlist is wired the way the topology says.
      "all_pairs": begin
        for (int unsigned t = 0; t < Devices; t++) begin
          for (int unsigned s = 0; s < Devices; s++) begin
            inj_fixed_dst[s] = 1'b1;
            inj_dst[s] = t;
            inj_remaining[s] = (s == t) ? 0 : 1;
          end
          for (int unsigned s = 0; s < Devices; s++) begin
            while (inj_remaining[s] != 0) @(posedge clk);
          end
          drain(60);
          expect_all_delivered();
        end
        $display("all_pairs: %0d flits over %0d ordered pairs", received_count,
                 Devices * (Devices - 1));
      end

      // Uniform random from every device at once, then stop and require the
      // mesh to empty itself. A fabric that deadlocks does not drain, so the
      // watchdog below is the verdict and the flit count is the evidence.
      "uniform": begin
        pattern = PatternUniform;
        run_all(BurstFlits);
        drain();
        expect_all_delivered();
        $display("uniform: %0d flits delivered, mean latency %0d cycles", received_count,
                 latency_sum / received_count);
      end

      // The same, with every destination stalling at random. Backpressure that
      // moves around is what turns a latent buffer-sharing bug into a deadlock,
      // and the fabric still has to drain once it stops.
      "stall": begin
        pattern = PatternUniform;
        fork
          begin : gen_stalls
            forever begin
              @(posedge clk);
              for (int unsigned d = 0; d < Devices; d++) begin
                eject_stall[d] = ($urandom_range(3, 0) == 0);
              end
              if (sent_count >= Devices * BurstFlits && received_count == sent_count) break;
            end
            eject_stall = '0;
          end
          begin : gen_traffic
            run_all(BurstFlits);
          end
        join_any
        run_all(0);
        eject_stall = '0;
        drain();
        expect_all_delivered();
        $display("stall: %0d flits delivered through random backpressure", received_count);
      end

      // Zero-load latency: one flit at a time, mesh otherwise empty, every
      // ordered pair. The model says LatencyPerHop * hops + LatencyOverhead and
      // this is where that is either confirmed or corrected.
      "latency": begin
        for (int unsigned s = 0; s < Devices; s++) begin
          for (int unsigned t = 0; t < Devices; t++) begin
            if (s == t) continue;
            latency_min = 32'hffff_ffff;
            latency_max = 0;
            inj_fixed_dst[s] = 1'b1;
            inj_dst[s] = t;
            inj_remaining[s] = 1;
            while (inj_remaining[s] != 0) @(posedge clk);
            drain(40);
            expect_all_delivered();

            measured = LatencyPerHop * hops_between(s, t) + LatencyOverhead;
            if (latency_min != measured) begin
              $fatal(1, "device %0d to %0d is %0d hops: measured %0d cycles, the model says %0d",
                     s, t, hops_between(s, t), latency_min, measured);
            end
          end
        end
        $display("latency: every ordered pair matches %0d*hops + %0d cycles", LatencyPerHop,
                 LatencyOverhead);
      end

      // Saturation, under each of the four patterns. The bound comes from the
      // generated package, which nocgen computed from this topology; the floor
      // is policy, and is what stops a regression passing quietly.
      "throughput_uniform", "throughput_transpose", "throughput_complement",
          "throughput_hotspot", "throughput_neighbour": begin
        case (test_case)
          "throughput_transpose":  pattern = PatternTranspose;
          "throughput_complement": pattern = PatternComplement;
          "throughput_hotspot":    pattern = PatternHotspot;
          "throughput_neighbour":  pattern = PatternNeighbour;
          default:                 pattern = PatternUniform;
        endcase
        // Fixed destinations for everything but uniform, so the pattern is the
        // pattern rather than a fresh draw per flit.
        if (pattern != PatternUniform) begin
          for (int unsigned s = 0; s < Devices; s++) begin
            inj_fixed_dst[s] = 1'b1;
            inj_dst[s] = destination(s);
          end
        end

        // Let the pipes fill before the clock starts.
        run_all(BurstFlits / 4);
        started = received_count;
        elapsed = cycle;
        run_all(BurstFlits);
        elapsed = cycle - elapsed;
        measured = throughput_per_mille(received_count - started, elapsed);

        drain();
        expect_all_delivered();

        // Two ceilings, and the lower one binds. The network's comes from
        // nocgen. The other is ejection: a destination takes one flit a cycle,
        // so a pattern that aims everything at a few of them cannot exceed
        // `destinations / devices` however good the fabric is.
        //
        // Counting distinct destinations rather than special-casing hotspot,
        // because the count is what actually matters and hotspot's is not one:
        // the self-addressing guard sends the target's own traffic elsewhere,
        // making it two.
        ceiling = 1000 * distinct_destinations() / Devices;
        if (ceiling > SaturationBoundPerMille) ceiling = SaturationBoundPerMille;

        case (pattern)
          PatternTranspose:  floor = FloorTranspose;
          PatternComplement: floor = FloorComplement;
          PatternHotspot:    floor = FloorHotspot;
          PatternNeighbour:  floor = FloorNeighbour;
          default:           floor = FloorUniform;
        endcase

        $display("%s: %0d.%0d%% of a flit per cycle per device (ceiling %0d.%0d%%, floor %0d.%0d%%), mean latency %0d",
                 test_case, measured / 10, measured % 10, ceiling / 10, ceiling % 10, floor / 10,
                 floor % 10, latency_sum / received_count);

        if (measured > ceiling) begin
          $fatal(1, "%0d per mille exceeds the ceiling of %0d -- the measurement is wrong",
                 measured, ceiling);
        end
        if (measured < floor) begin
          $fatal(1, "%0d per mille is below the floor of %0d -- throughput regressed", measured,
                 floor);
        end
      end

      // One burst on each of the four classes, at once. What this catches is a
      // class miswired in the *netlist*: the RTL's four instances are already
      // covered by chi_xp_test.
      "all_classes": begin
        pattern = PatternUniform;
        fork
          begin : gen_req
            run_all(32);
          end
          begin : gen_others
            send_other_classes();
          end
        join
        drain();
        expect_all_delivered();
        check_other_classes();
        $display("all_classes: REQ %0d, and one flit each way on RSP, DAT and SNP",
                 received_count);
      end

      default: $fatal(1, "unknown case '%s'", test_case);
    endcase

    $finish;
  end

  ////////////////////////////////////////////////////////////////////////////////////////////////
  // The other three classes
  //
  // One flit from device 0 to device 15 on each, which is a six-hop path across
  // the whole mesh. Enough to prove the netlist connected them; not an attempt
  // to test the switch again.
  ////////////////////////////////////////////////////////////////////////////////////////////////

  localparam int unsigned OtherSrc = 0;
  localparam int unsigned OtherDst = Devices - 1;

  int unsigned rsp_arrived;
  int unsigned dat_arrived;
  int unsigned snp_arrived;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rsp_arrived <= 0;
      dat_arrived <= 0;
      snp_arrived <= 0;
    end else begin
      if (rsp_eject_valid[OtherDst]) rsp_arrived <= rsp_arrived + 1;
      if (dat_eject_valid[OtherDst]) dat_arrived <= dat_arrived + 1;
      if (snp_eject_valid[OtherDst]) snp_arrived <= snp_arrived + 1;
    end
  end

  task automatic send_other_classes();
    chi_pkg::chi_rsp_t rsp_flit;
    chi_pkg::chi_dat_t dat_flit;
    chi_noc_snp_flit_t snp_flit;

    rsp_flit = '0;
    rsp_flit.opcode = chi_pkg::CHI_RSP_COMP_ACK;
    rsp_flit.qos = 4'h8;
    rsp_flit.tgt_id = DeviceNodeId[OtherDst];
    rsp_flit.src_id = DeviceNodeId[OtherSrc];

    dat_flit = '0;
    dat_flit.opcode = chi_pkg::CHI_DAT_COMP_DATA;
    dat_flit.qos = 4'h8;
    dat_flit.tgt_id = DeviceNodeId[OtherDst];
    dat_flit.src_id = DeviceNodeId[OtherSrc];

    snp_flit = '0;
    snp_flit.snp.opcode = chi_pkg::CHI_SNP_ONCE;
    snp_flit.snp.qos = 4'h8;
    snp_flit.snp.src_id = DeviceNodeId[OtherSrc];
    snp_flit.tgt_id = DeviceNodeId[OtherDst];

    @(negedge clk);
    rsp_inject_flit[OtherSrc]  = rsp_flit;
    dat_inject_flit[OtherSrc]  = dat_flit;
    snp_inject_flit[OtherSrc]  = snp_flit;
    rsp_inject_valid[OtherSrc] = 1'b1;
    dat_inject_valid[OtherSrc] = 1'b1;
    snp_inject_valid[OtherSrc] = 1'b1;

    while (!(rsp_inject_ready[OtherSrc] && dat_inject_ready[OtherSrc] &&
             snp_inject_ready[OtherSrc])) begin
      @(posedge clk);
    end
    @(negedge clk);
    rsp_inject_valid[OtherSrc] = 1'b0;
    dat_inject_valid[OtherSrc] = 1'b0;
    snp_inject_valid[OtherSrc] = 1'b0;
  endtask

  function automatic void check_other_classes();
    if (rsp_arrived != 1) $fatal(1, "RSP: %0d flits arrived at device %0d", rsp_arrived, OtherDst);
    if (dat_arrived != 1) $fatal(1, "DAT: %0d flits arrived at device %0d", dat_arrived, OtherDst);
    if (snp_arrived != 1) $fatal(1, "SNP: %0d flits arrived at device %0d", snp_arrived, OtherDst);
  endfunction

  initial begin
    for (int unsigned d = 0; d < Devices; d++) begin
      rsp_inject_valid[d] = 1'b0;
      dat_inject_valid[d] = 1'b0;
      snp_inject_valid[d] = 1'b0;
      rsp_inject_flit[d]  = '0;
      dat_inject_flit[d]  = '0;
      snp_inject_flit[d]  = '0;
    end
  end

  ////////////////////////////////////////////////////////////////////////////////////////////////
  // Timeout
  //
  // The verdict for deadlock. A mesh that has stopped making progress does not
  // announce it, so this is what turns a hang into a message with the flit
  // counts in it.
  ////////////////////////////////////////////////////////////////////////////////////////////////

  initial begin
    wait (rst_n);
    repeat (Timeout) @(posedge clk);
    $fatal(1, "timeout in '%s': sent %0d, received %0d, %0d still in the mesh", test_case,
           sent_count, received_count, sent_count - received_count);
  end

endmodule
