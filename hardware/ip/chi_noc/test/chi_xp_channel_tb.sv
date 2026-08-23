// One crosspoint switch, with its six ports wired to nothing but itself.
//
// The partners on each port are `chi_link_tx_channel` and `chi_link_rx_channel`
// -- the same modules the crosspoint is built from, facing the other way -- so
// the credit accounting is exercised against a real counterpart with no mesh
// and no CHI protocol in the build. Everything the switch does is reachable in
// a few hundred cycles from here, which is where an off-by-one credit should be
// found rather than in a 4x4 mesh where it looks like a deadlock.
//
// The flits are synthetic and 32 bits wide. `chi_xp_channel` reads exactly two
// fields -- TgtID and QoS -- and cannot tell which channel class it is, so
// giving it a CHI flit here would test nothing extra and cost 422 bits per port.
// What the spare bits buy instead is a source and a sequence number, which is
// what makes "in order, exactly once" checkable.
//
// Traffic comes from one process per port rather than one process driving all
// six, because a single process would serialise injection and never make two
// inputs contend -- which is the only interesting thing a switch does.
//
// One model, several cases: `+case=` picks which. See BUILD.bazel.
module chi_xp_channel_tb #(
    // A half period, not a period: `time` is integral and `Period / 2` rounds to
    // zero at a coarse precision, which appears much later as an inactive region
    // that would not converge.
    parameter time ClkHalfPeriod = 1ns,

    parameter int unsigned Credits = 4,

    // Passed to the switch and waited past by the `starved` case, so the two
    // cannot disagree about how long is too long.
    parameter int unsigned StarvationLimit = 4096,

    parameter int unsigned Timeout = 50000
);

  import chi_noc_pkg::*;

  localparam int unsigned Ports = CHI_XP_PORTS;
  localparam int unsigned FlitWidth = 32;

  // Where the crosspoint under test sits. Interior, so all four compass
  // directions are reachable and every turn is expressible.
  localparam int unsigned XIndex = 1;
  localparam int unsigned YIndex = 1;

  ////////////////////////////////////////////////////////////////////////////////////////////////
  // The synthetic flit
  //
  //   [3:0]   QoS      where chi_typedef.svh puts it on every CHI channel
  //   [14:4]  TgtID    likewise, on the three channels that have one
  //   [17:15] source   which port injected it
  //   [31:18] sequence counts from 1, so a live flit is never all-zero and
  //                    cannot be mistaken for an L-Credit return
  ////////////////////////////////////////////////////////////////////////////////////////////////

  localparam int unsigned TgtIdOffset = 4;
  localparam int unsigned QosOffset = 0;
  localparam int unsigned QosWidth = 4;

  function automatic logic [FlitWidth-1:0] make_flit(int unsigned src, chi_noc_nodeid_t tgt,
                                                     logic [3:0] qos, int unsigned seq);
    return {seq[13:0], src[2:0], tgt, qos};
  endfunction

  // A NodeID that routes to `port` from (XIndex, YIndex).
  function automatic chi_noc_nodeid_t target_for(int unsigned port);
    case (port)
      CHI_XP_EAST:  return chi_noc_node_id(chi_noc_x_t'(XIndex + 1), chi_noc_y_t'(YIndex), 3'd0);
      CHI_XP_WEST:  return chi_noc_node_id(chi_noc_x_t'(XIndex - 1), chi_noc_y_t'(YIndex), 3'd0);
      CHI_XP_NORTH: return chi_noc_node_id(chi_noc_x_t'(XIndex), chi_noc_y_t'(YIndex + 1), 3'd0);
      CHI_XP_SOUTH: return chi_noc_node_id(chi_noc_x_t'(XIndex), chi_noc_y_t'(YIndex - 1), 3'd0);
      CHI_XP_P0:    return chi_noc_node_id(chi_noc_x_t'(XIndex), chi_noc_y_t'(YIndex), 3'd0);
      default:      return chi_noc_node_id(chi_noc_x_t'(XIndex), chi_noc_y_t'(YIndex), 3'd1);
    endcase
  endfunction

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

  ////////////////////////////////////////////////////////////////////////////////////////////////
  // The switch, and a link partner on every port
  ////////////////////////////////////////////////////////////////////////////////////////////////

  // Unpacked, because each port's injector is its own process and a process per
  // bit of one packed vector is a multiple-driver argument nobody needs.
  logic                 inject_valid[Ports];
  logic                 inject_ready[Ports];
  logic [FlitWidth-1:0] inject_flit [Ports];

  logic [Ports-1:0]                eject_valid;
  logic [Ports-1:0]                eject_ready;
  logic [Ports-1:0][FlitWidth-1:0] eject_flit;

  logic [Ports-1:0]                dut_rx_flitv;
  logic [Ports-1:0][FlitWidth-1:0] dut_rx_flit;
  logic [Ports-1:0]                dut_rx_is_lcrd;
  logic [Ports-1:0]                dut_rx_lcrdv;
  logic [Ports-1:0]                dut_tx_lcrdv;
  logic [Ports-1:0]                dut_tx_flitv;
  logic [Ports-1:0][FlitWidth-1:0] dut_tx_flit;
  logic [Ports-1:0]                dut_tx_flitpend;

  chi_xp_channel #(
      .FlitWidth  (FlitWidth),
      .TgtIdOffset(TgtIdOffset),
      .TgtIdWidth (CHI_NOC_NODEID_WIDTH),
      .QosOffset  (QosOffset),
      .QosWidth   (QosWidth),
      .XIndex     (XIndex),
      .YIndex     (YIndex),
      .PortEnable ('1),
      .Credits    (Credits),
      .StarvationLimit(StarvationLimit)
  ) i_dut (
      .clk_i              (clk),
      .rst_ni             (rst_n),
      .rx_flitv_i         (dut_rx_flitv),
      .rx_flit_i          (dut_rx_flit),
      .rx_is_lcrd_return_i(dut_rx_is_lcrd),
      .rx_lcrdv_o         (dut_rx_lcrdv),
      .tx_lcrdv_i         (dut_tx_lcrdv),
      .tx_flitpend_o      (dut_tx_flitpend),
      .tx_flitv_o         (dut_tx_flitv),
      .tx_flit_o          (dut_tx_flit)
  );

  for (genvar p = 0; p < Ports; p++) begin : gen_partner
    // Into the switch. A real transmitter, so injection obeys the credits the
    // switch grants rather than assuming they exist.
    chi_link_tx_channel #(
        .FlitWidth(FlitWidth)
    ) i_inject (
        .clk_i     (clk),
        .rst_ni    (rst_n),
        .state_i   (chi_pkg::CHI_LINK_RUN),
        .flit_i    (inject_flit[p]),
        .valid_i   (inject_valid[p]),
        .ready_o   (inject_ready[p]),
        .flitpend_o(),
        .flitv_o   (dut_rx_flitv[p]),
        .flit_o    (dut_rx_flit[p]),
        .lcrdv_i   (dut_rx_lcrdv[p]),
        .credits_o ()
    );

    // Live flits count from 1, so all-zero is unambiguous.
    assign dut_rx_is_lcrd[p] = dut_rx_flitv[p] && (dut_rx_flit[p] == '0);

    // Out of the switch. A real receiver, so the switch's transmitters are
    // credit-limited exactly as they would be by a neighbouring crosspoint.
    chi_link_rx_channel #(
        .FlitWidth(FlitWidth),
        .Credits  (Credits)
    ) i_eject (
        .clk_i           (clk),
        .rst_ni          (rst_n),
        .state_i         (chi_pkg::CHI_LINK_RUN),
        .flitpend_i      (dut_tx_flitpend[p]),
        .flitv_i         (dut_tx_flitv[p]),
        .flit_i          (dut_tx_flit[p]),
        .is_lcrd_return_i(dut_tx_flitv[p] && (dut_tx_flit[p] == '0)),
        .lcrdv_o         (dut_tx_lcrdv[p]),
        .flit_o          (eject_flit[p]),
        .valid_o         (eject_valid[p]),
        .ready_i         (eject_ready[p]),
        .outstanding_o   ()
    );
  end

  ////////////////////////////////////////////////////////////////////////////////////////////////
  // The scoreboard
  //
  // Order is guaranteed per (source, destination) and nowhere else -- two
  // sources into one output interleave however arbitration decides -- so the
  // expectation is one queue per pair, and the flit carries the source that says
  // which queue it belongs in.
  //
  // Injectors push at the negative edge and this pops at the positive one, so
  // the two never touch a queue in the same time step.
  ////////////////////////////////////////////////////////////////////////////////////////////////

  // Counters rather than queues, indexed `src * Ports + dst`.
  //
  // Sequence numbers run per *pair* instead of per source, which turns "the
  // flits from s to d arrive in order and none is lost or duplicated" into
  // "the next one to arrive is the next one sent" -- an integer compare, no
  // dynamic storage. An array of queues would express it directly and does not
  // survive Verilator: writing one element of `int q[N][$]` was observed to
  // change another, which shows up as a perfectly correct flit failing an
  // ordering check against a different pair's expectation.
  int unsigned next_seq[Ports*Ports];  // written by the injectors
  int unsigned want_seq[Ports*Ports];  // read and written by the scoreboard
  int unsigned sent_count;
  int unsigned received_count;

  function automatic int unsigned pair(int unsigned src, int unsigned dst);
    return src * Ports + dst;
  endfunction

  logic [Ports-1:0] eject_stall;

  for (genvar p = 0; p < Ports; p++) begin : gen_eject_ready
    assign eject_ready[p] = !eject_stall[p];
  end

  int unsigned seen_src;
  int unsigned seen_seq;
  int unsigned seen_pair;
  int unsigned seen_now;

  always_ff @(posedge clk) begin
    if (rst_n) begin
      seen_now = 0;
      for (int unsigned d = 0; d < Ports; d++) begin
        if (eject_valid[d] && eject_ready[d]) begin
          seen_src  = {29'd0, eject_flit[d][17:15]};
          seen_seq  = {18'd0, eject_flit[d][31:18]};
          seen_pair = pair(seen_src, d);

          if (seen_seq != want_seq[seen_pair]) begin
            $fatal(1, "port %0d: flit from %0d out of order -- got seq %0d, wanted %0d", d,
                   seen_src, seen_seq, want_seq[seen_pair]);
          end
          want_seq[seen_pair] = want_seq[seen_pair] + 1;
          // Blocking, and accumulated: two ports may eject in the same cycle,
          // and a non-blocking increment would count that once.
          seen_now = seen_now + 1;
        end
      end
      received_count = received_count + seen_now;
    end
  end

  ////////////////////////////////////////////////////////////////////////////////////////////////
  // The injectors
  //
  // One process per port, so that six sources really do contend. Each owns its
  // own sequence counter and its own row of the expectation, so nothing is
  // shared between them.
  ////////////////////////////////////////////////////////////////////////////////////////////////

  int unsigned inj_remaining[Ports];  // flits still to send
  int unsigned inj_dst      [Ports];
  logic [3:0]  inj_qos      [Ports];

  // Set directly by the negative cases, which drive one malformed flit and wait
  // for an assertion rather than expecting delivery.
  logic                 raw_drive[Ports];
  logic [FlitWidth-1:0] raw_flit [Ports];

  for (genvar p = 0; p < Ports; p++) begin : gen_injector
    initial begin
      inject_valid[p] = 1'b0;
      inject_flit[p]  = '0;
      inj_remaining[p] = 0;
      inj_dst[p] = 0;
      inj_qos[p] = 4'h8;
      raw_drive[p] = 1'b0;
      raw_flit[p] = '0;

      forever begin
        @(negedge clk);
        if (!rst_n) begin
          inject_valid[p] = 1'b0;
        end else if (raw_drive[p]) begin
          inject_flit[p]  = raw_flit[p];
          inject_valid[p] = 1'b1;
        end else if (inj_remaining[p] != 0) begin
          inject_flit[p]  = make_flit(p, target_for(inj_dst[p]), inj_qos[p],
                                      next_seq[pair(p, inj_dst[p])]);
          inject_valid[p] = 1'b1;
          if (inject_ready[p]) begin
            next_seq[pair(p, inj_dst[p])] = next_seq[pair(p, inj_dst[p])] + 1;
            inj_remaining[p]--;
            sent_count++;
          end
        end else begin
          inject_valid[p] = 1'b0;
        end
      end
    end
  end

  // Queues `count` flits from `src` to `dst` and returns once they are all
  // accepted by the switch. The injector process does the sending.
  task automatic send(input int unsigned src, input int unsigned dst, input int unsigned count,
                      input logic [3:0] qos = 4'h8);
    @(negedge clk);
    inj_dst[src] = dst;
    inj_qos[src] = qos;
    inj_remaining[src] = count;
    while (inj_remaining[src] != 0) @(posedge clk);
  endtask

  task automatic drain(input int unsigned quiet_cycles = 200);
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
    for (int unsigned s = 0; s < Ports; s++) begin
      for (int unsigned d = 0; d < Ports; d++) begin
        if (next_seq[pair(s, d)] != want_seq[pair(s, d)]) begin
          $fatal(1, "%0d flits from port %0d to port %0d never arrived",
                 next_seq[pair(s, d)] - want_seq[pair(s, d)], s, d);
        end
      end
    end
  endfunction

  ////////////////////////////////////////////////////////////////////////////////////////////////
  // The cases
  ////////////////////////////////////////////////////////////////////////////////////////////////

  initial begin
    eject_stall = '0;
    sent_count = 0;
    received_count = 0;
    for (int unsigned i = 0; i < Ports * Ports; i++) begin
      next_seq[i] = 0;
      want_seq[i] = 0;
    end

    wait (rst_n);
    repeat (4) @(posedge clk);

    case (test_case)

      // Every turn the switch is supposed to have, one flit at a time, with the
      // fabric emptied between each. Twenty-six of the thirty-six pairs: four
      // are missing because a flit arriving vertically may not leave
      // horizontally, and six because nothing may leave the way it came. Those
      // ten are not untested -- `bad_turn` and `self` drive them and require the
      // switch to notice.
      "route": begin
        for (int unsigned s = 0; s < Ports; s++) begin
          for (int unsigned d = 0; d < Ports; d++) begin
            if (chi_xp_turn_legal(s, d)) begin
              send(s, d, 1);
              drain(20);
              expect_all_delivered();
            end
          end
        end
      end

      // One source, one destination, many flits. The only ordering the link
      // layer promises, and the only one the switch must keep.
      "order": begin
        send(CHI_XP_WEST, CHI_XP_EAST, 64);
        drain();
        expect_all_delivered();
      end

      // Every source to a different destination at once, rotated, so every
      // output arbitrates between five inputs over the run and every input
      // contends for five outputs.
      "all_to_all": begin
        for (int unsigned offset = 1; offset < Ports; offset++) begin
          for (int unsigned s = 0; s < Ports; s++) begin
            // Rotate, and skip the source whose turn this round is one the
            // switch does not have.
            inj_dst[s] = (s + offset) % Ports;
            inj_qos[s] = 4'h8;
            inj_remaining[s] = chi_xp_turn_legal(s, (s + offset) % Ports) ? 16 : 0;
          end
          // All six inject concurrently; wait for the last to be accepted.
          for (int unsigned s = 0; s < Ports; s++) begin
            while (inj_remaining[s] != 0) @(posedge clk);
          end
          drain();
          expect_all_delivered();
        end
      end

      // One output stalled: everything addressed elsewhere must keep moving.
      // A switch whose outputs shared a buffer would fail here, and that sharing
      // is exactly what would make the four channel classes deadlock each other.
      "backpressure": begin
        eject_stall[CHI_XP_EAST] = 1'b1;

        // Fill the east path and back it up into the west input. The injector
        // keeps trying; `send` would never return, so this one is left running.
        inj_dst[CHI_XP_WEST] = CHI_XP_EAST;
        inj_remaining[CHI_XP_WEST] = 64;

        repeat (200) @(posedge clk);

        // The other five outputs are untouched by that.
        send(CHI_XP_SOUTH, CHI_XP_NORTH, 16);
        send(CHI_XP_P0, CHI_XP_P1, 16);
        send(CHI_XP_NORTH, CHI_XP_P0, 16);

        if (received_count == 0) $fatal(1, "a stalled output stopped every other output");
        if (inj_remaining[CHI_XP_WEST] == 0) begin
          $fatal(1, "the stalled output accepted everything sent to it");
        end

        // Release it; everything must then arrive.
        eject_stall = '0;
        while (inj_remaining[CHI_XP_WEST] != 0) @(posedge clk);
        drain();
        expect_all_delivered();
      end

      // A high-QoS source and a low-QoS one contending for the same output.
      // What is checked is that the priority path delivers everything: a
      // starved input trips the counter inside the switch, so passing means
      // neither class was locked out.
      "qos": begin
        // Both turns have to be ones the switch has, so the contenders are the
        // west input (horizontal, may continue east) and a device port (may go
        // anywhere). South to east is not a turn and is `bad_turn`'s job.
        inj_dst[CHI_XP_WEST] = CHI_XP_EAST;
        inj_qos[CHI_XP_WEST] = 4'h0;
        inj_remaining[CHI_XP_WEST] = 32;

        inj_dst[CHI_XP_P0] = CHI_XP_EAST;
        inj_qos[CHI_XP_P0] = 4'hf;
        inj_remaining[CHI_XP_P0] = 32;

        while (inj_remaining[CHI_XP_WEST] != 0 || inj_remaining[CHI_XP_P0] != 0) begin
          @(posedge clk);
        end
        drain();
        expect_all_delivered();
      end

      // Every input hammering one output, for many times the credit count. The
      // receiver may not accept a flit it granted no credit for, and
      // chi_link_rx_channel asserts if the switch ever sends one -- so passing
      // means the credit accounting held under sustained oversubscription.
      "credit": begin
        for (int unsigned s = 0; s < Ports; s++) begin
          if (s != CHI_XP_P0) begin
            inj_dst[s] = CHI_XP_P0;
            inj_qos[s] = 4'h8;
            inj_remaining[s] = 8 * Credits;
          end
        end
        for (int unsigned s = 0; s < Ports; s++) begin
          while (inj_remaining[s] != 0) @(posedge clk);
        end
        drain();
        expect_all_delivered();
      end

      ////////////////////////////////////////////////////////////////////////////////////////////
      // Negative cases. Each drives something no correct neighbour would, and
      // passing means the switch failed to notice.
      ////////////////////////////////////////////////////////////////////////////////////////////

      // A flit arriving from the north asking to go east: the turn dimension-
      // order routing does not have, and a cycle in the channel dependency
      // graph if it were allowed.
      "bad_turn": begin
        raw_flit[CHI_XP_NORTH]  = make_flit(CHI_XP_NORTH, target_for(CHI_XP_EAST), 4'h8, 1);
        raw_drive[CHI_XP_NORTH] = 1'b1;
        repeat (100) @(posedge clk);
        $fatal(1, "the forbidden turn was not noticed");
      end

      // Addressed to a device port no crosspoint has -- the NodeID port field is
      // three bits wide and only two of its values name a port.
      "nowhere": begin
        raw_flit[CHI_XP_WEST] = make_flit(
            CHI_XP_WEST, chi_noc_node_id(chi_noc_x_t'(XIndex), chi_noc_y_t'(YIndex), 3'd5), 4'h8, 1
        );
        raw_drive[CHI_XP_WEST] = 1'b1;
        repeat (100) @(posedge clk);
        $fatal(1, "a flit addressed to no port was not noticed");
      end

      // An output stalled for longer than anything legitimate, with an input
      // waiting on it throughout. `backpressure` above proves the other five
      // outputs keep running; this one proves the switch says so rather than
      // hanging silently, which is the difference between a message naming the
      // port and a timeout naming nothing.
      "starved": begin
        eject_stall[CHI_XP_EAST] = 1'b1;
        inj_dst[CHI_XP_WEST] = CHI_XP_EAST;
        inj_remaining[CHI_XP_WEST] = 1000000;
        repeat (StarvationLimit + 200) @(posedge clk);
        $fatal(1, "an input starved for %0d cycles was not noticed", StarvationLimit);
      end

      // Back out of the port it came in by, which means two nodes share a NodeID
      // or one is addressing itself.
      "self": begin
        raw_flit[CHI_XP_P0]  = make_flit(CHI_XP_P0, target_for(CHI_XP_P0), 4'h8, 1);
        raw_drive[CHI_XP_P0] = 1'b1;
        repeat (100) @(posedge clk);
        $fatal(1, "a flit addressed back to its own port was not noticed");
      end

      default: $fatal(1, "unknown case '%s'", test_case);
    endcase

    $display("%s: %0d flits, all delivered in order", test_case, received_count);
    $finish;
  end

  ////////////////////////////////////////////////////////////////////////////////////////////////
  // Timeout
  ////////////////////////////////////////////////////////////////////////////////////////////////

  initial begin
    wait (rst_n);
    repeat (Timeout) @(posedge clk);
    $fatal(1, "timeout in '%s': sent %0d, received %0d", test_case, sent_count, received_count);
  end

endmodule
