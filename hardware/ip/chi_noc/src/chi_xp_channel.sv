// One channel class through one crosspoint: six ports in, six ports out.
//
// A crosspoint is four of these -- REQ, RSP, DAT and SNP -- sharing nothing but
// a clock. That is not a saving, it is the deadlock argument: CHI makes progress
// only if each class can move while the others are blocked, and separate
// switches with separate credit pools make that structural rather than a rule
// someone has to remember.
//
// This module knows five numbers about the flits it carries -- how wide they
// are, and where TgtID and QoS sit inside them -- and nothing else. It never
// decodes an opcode, never sees a struct, and cannot tell which of the four
// classes it is. Everything CHI-specific is in chi_noc_flit_pkg, which computes
// those five numbers; see //hardware/ip/chi_noc/README.md.
//
////////////////////////////////////////////////////////////////////////////////
// The shape, and why
////////////////////////////////////////////////////////////////////////////////
//
// Each input keeps **one queue per output** (chi_xp_input_buffer), so a flit
// whose output is busy no longer holds up the flit behind it bound somewhere
// free. A single FIFO per input made that impossible and cost about a third of
// the fabric's throughput; see the README's table.
//
// Deciding what moves is a bipartite match between six inputs and six outputs,
// because a payload memory has one read port and an input sends one flit a
// cycle. Each pass is:
//
//   eligibility  a queue head exists, and its output has a credit to spare
//   phase one    each free output picks a free input, highest QoS class first
//   phase two    each free input accepts one of the outputs that picked it
//
// `MatchIterations` passes of that, and three is measured rather than chosen --
// see the parameter.
//
// The credit check belongs in **eligibility**, not in the final grant. An
// output with no credit that can still be picked consumes its input's one slot
// for the cycle, and head-of-line blocking reappears one level up.
//
////////////////////////////////////////////////////////////////////////////////
// Two stages, because the payload memory is written as an SRAM
////////////////////////////////////////////////////////////////////////////////
//
// A read result appears the cycle after its address and is then gone, so the
// scheduler may only commit a read that is certain to have somewhere to land.
// Hence the reservation: an output is eligible while `credits - committed > 0`,
// where `committed` is the flit already on its way out of a memory. Without it
// a read arrives at a transmitter with no credit and the flit is lost with
// nothing to say so.
//
// The cost is a cycle per hop: zero-load latency is `3H + 4`, and was `2H + 4`
// when the buffer was flops read combinationally. Reclaiming it means the
// memory's output register *replacing* the transmitter's flit register, which
// puts the crossbar's 422-bit mux after that register rather than before it.
// That is a decision to make with a floorplan, not a refactor.
module chi_xp_channel
  import chi_noc_pkg::CHI_XP_PORTS;
#(
    // The five numbers. See chi_noc_flit_pkg.
    parameter int unsigned FlitWidth   = 1,
    parameter int unsigned TgtIdOffset = 0,
    parameter int unsigned TgtIdWidth  = 1,
    parameter int unsigned QosOffset   = 0,
    parameter int unsigned QosWidth    = 4,

    // Where this crosspoint sits, which is what routing compares against.
    parameter int unsigned XIndex = 0,
    parameter int unsigned YIndex = 0,

    // Which of the six ports exist. A crosspoint at an edge, or with one device,
    // has fewer, and a disabled port costs no logic rather than being tied off.
    parameter logic [CHI_XP_PORTS-1:0] PortEnable = '1,

    // Entries per input, and so also the L-Credits granted for it. Six because
    // the credit round trip is five cycles and anything below that underruns;
    // measured, see the README.
    parameter int unsigned Credits = 8,

    // QoS priority classes, taken from the top bits of QoS. Four is OpenNoC's
    // choice and CHI's intent.
    parameter int unsigned PrioBits = 2,

    // Passes of the request/grant/accept match per cycle.
    //
    // One is not enough, and the measurement is what says so: a single pass
    // leaves an output idle whenever several of them pick the same input, and
    // that loss exceeded everything head-of-line queues had bought. The old
    // single-FIFO switch had no such loss -- an input offered one flit to one
    // output, so its match was perfect and only its *choice* was poor.
    //
    // Each pass costs an output arbitration and an input arbitration in series,
    // so this is the parameter that trades throughput against the clock.
    parameter int unsigned MatchIterations = 3,

    // Cycles an input may hold something to send and send nothing.
    parameter int unsigned StarvationLimit = 4096
) (
    input logic clk_i,
    input logic rst_ni,

    // From the neighbours and the devices.
    input  logic [CHI_XP_PORTS-1:0]                rx_flitv_i,
    input  logic [CHI_XP_PORTS-1:0][FlitWidth-1:0] rx_flit_i,
    // Whether each arriving flit is an L-Credit return. Decoded by the caller,
    // which has the typed struct; opcode zero means it on every channel.
    input  logic [CHI_XP_PORTS-1:0]                rx_is_lcrd_return_i,
    output logic [CHI_XP_PORTS-1:0]                rx_lcrdv_o,

    // To the neighbours and the devices.
    input  logic [CHI_XP_PORTS-1:0]                tx_lcrdv_i,
    output logic [CHI_XP_PORTS-1:0]                tx_flitpend_o,
    output logic [CHI_XP_PORTS-1:0]                tx_flitv_o,
    output logic [CHI_XP_PORTS-1:0][FlitWidth-1:0] tx_flit_o
);

  localparam int unsigned Ports = CHI_XP_PORTS;
  localparam int unsigned PortIdxWidth = $clog2(Ports);
  localparam int unsigned CreditWidth = $clog2(chi_pkg::CHI_MAX_LCREDITS + 1);

  // Mesh links never power down: the LINKACTIVE handshake exists for a link to a
  // device that may go away, and both ends of a link inside the fabric come out
  // of the same reset. A device-facing port that needs activation gets it at the
  // boundary, in the agent, rather than in every crosspoint in the mesh.
  chi_pkg::chi_link_state_e link_state;
  assign link_state = chi_pkg::CHI_LINK_RUN;

  ////////////////////////////////////////////////////////////////////////////////////////////////
  // Inputs
  ////////////////////////////////////////////////////////////////////////////////////////////////

  // Worked out once, as a flit arrives, and then remembered as a choice of
  // queue. Nothing recomputes a route from a flit sitting in a memory.
  chi_noc_pkg::chi_xp_port_mask_t [Ports-1:0] arriving_dest;
  logic [Ports-1:0][PrioBits-1:0]             arriving_prio;
  logic [Ports-1:0]                           arriving;

  // Everything the scheduler reads: six valid bits and six priorities per
  // input, eighteen bits each and a hundred and eight in all.
  logic [Ports-1:0][Ports-1:0]               head_valid;
  logic [Ports-1:0][Ports-1:0][PrioBits-1:0] head_prio;
  logic [Ports-1:0]                          pop;
  logic [Ports-1:0][PortIdxWidth-1:0]        pop_port;
  logic [Ports-1:0][FlitWidth-1:0]           pop_flit;

  for (genvar p = 0; p < Ports; p++) begin : gen_input
    if (PortEnable[p]) begin : gen_present
      assign arriving[p] = rx_flitv_i[p] && !rx_is_lcrd_return_i[p];

      assign arriving_dest[p] = chi_noc_pkg::chi_xp_route(
          chi_noc_pkg::chi_noc_x_t'(XIndex),
          chi_noc_pkg::chi_noc_y_t'(YIndex),
          chi_noc_pkg::chi_noc_nodeid_t'(rx_flit_i[p][TgtIdOffset+:TgtIdWidth])
      );

      // The top bits of QoS. CHI's sixteen levels collapse to four classes,
      // which is what the arbiters below distinguish.
      assign arriving_prio[p] = rx_flit_i[p][QosOffset+QosWidth-PrioBits+:PrioBits];

      chi_xp_input_buffer #(
          .FlitWidth(FlitWidth),
          .PrioBits (PrioBits),
          .Credits  (Credits)
      ) i_buffer (
          .clk_i,
          .rst_ni,
          .state_i         (link_state),
          .flitv_i         (rx_flitv_i[p]),
          .flit_i          (rx_flit_i[p]),
          .is_lcrd_return_i(rx_is_lcrd_return_i[p]),
          .lcrdv_o         (rx_lcrdv_o[p]),
          .dest_i          (arriving_dest[p]),
          .prio_i          (arriving_prio[p]),
          .head_valid_o    (head_valid[p]),
          .head_prio_o     (head_prio[p]),
          .pop_i           (pop[p]),
          .pop_port_i      (pop_port[p]),
          .pop_flit_o      (pop_flit[p])
      );

    end else begin : gen_absent
      assign rx_lcrdv_o[p]    = 1'b0;
      assign arriving[p]      = 1'b0;
      assign arriving_dest[p] = '0;
      assign arriving_prio[p] = '0;
      assign head_valid[p]    = '0;
      assign head_prio[p]     = '0;
      assign pop_flit[p]      = '0;
    end
  end

  ////////////////////////////////////////////////////////////////////////////////////////////////
  // What each output has room for
  ////////////////////////////////////////////////////////////////////////////////////////////////

  logic [Ports-1:0][CreditWidth-1:0] tx_credits;

  // A flit already on its way out of a payload memory, addressed to this output.
  logic [Ports-1:0]                   committed_q;
  logic [Ports-1:0][PortIdxWidth-1:0] committed_from_q;

  // Room for one more: the credits this output holds, less the one the flit
  // already in flight will spend when it lands next cycle.
  logic [Ports-1:0] credit_ok;

  for (genvar o = 0; o < Ports; o++) begin : gen_room
    assign credit_ok[o] =
        PortEnable[o] && (tx_credits[o] > CreditWidth'(committed_q[o] ? 1 : 0));
  end

  ////////////////////////////////////////////////////////////////////////////////////////////////
  // The match
  //
  // `MatchIterations` passes. Each pass has every still-free output pick a
  // still-free input, then has every still-free input accept one of the outputs
  // that picked it; whatever is matched drops out and the next pass runs on
  // what is left.
  //
  // Phase two reads phase one's `idx_o` and not its `gnt_o`, because `gnt_o`
  // depends on `gnt_i` and `gnt_i` here is the outcome of phase two -- reading
  // it would close a combinational loop. `idx_o` is a function of the requests
  // alone.
  //
  // A round-robin pointer advances only when its pass produced a match, which
  // is what makes two outputs contending for one input pick differently next
  // cycle instead of colliding again.
  ////////////////////////////////////////////////////////////////////////////////////////////////

  // Whatever every pass agreed on.
  logic [Ports-1:0]                   taken;     // [output]
  logic [Ports-1:0][PortIdxWidth-1:0] chosen_idx;  // [output] which input

  // Still unmatched at the start of each pass.
  logic [Ports-1:0] input_free [MatchIterations+1];
  logic [Ports-1:0] output_free[MatchIterations+1];

  logic [MatchIterations-1:0][Ports-1:0]                   pass_taken;
  logic [MatchIterations-1:0][Ports-1:0][PortIdxWidth-1:0] pass_chosen;
  logic [MatchIterations-1:0][Ports-1:0]                   pass_pop;
  logic [MatchIterations-1:0][Ports-1:0][PortIdxWidth-1:0] pass_pop_port;

  assign input_free[0]  = PortEnable;
  assign output_free[0] = PortEnable;

  for (genvar k = 0; k < MatchIterations; k++) begin : gen_pass
    logic [Ports-1:0]                   offered;
    logic [Ports-1:0][PortIdxWidth-1:0] chosen;
    logic [Ports-1:0][Ports-1:0]        accepted;  // [input][output]

    // -- phase one: each free output picks a free input ------------------------
    for (genvar o = 0; o < Ports; o++) begin : gen_output_arb
      if (PortEnable[o]) begin : gen_present
        logic [Ports-1:0] request;
        for (genvar p = 0; p < Ports; p++) begin : gen_request
          assign request[p] =
              head_valid[p][o] & credit_ok[o] & input_free[k][p] & output_free[k][o];
        end

        // The highest class asking for this output, and then only those asking
        // at it. A lower class can never win here, which is what a coverage bin
        // in //hardware/ip/chi_noc/test requires to stay empty.
        logic [PrioBits-1:0] top_prio;
        always_comb begin
          top_prio = '0;
          for (int unsigned p = 0; p < Ports; p++) begin
            if (request[p] && (head_prio[p][o] > top_prio)) top_prio = head_prio[p][o];
          end
        end

        logic [Ports-1:0] eligible;
        for (genvar p = 0; p < Ports; p++) begin : gen_eligible
          assign eligible[p] = request[p] & (head_prio[p][o] == top_prio);
        end

        cc_rr_arb_tree #(
            .NumIn    (Ports),
            .DataWidth(1),
            .AxiVldRdy(1'b1)
        ) i_arb (
            .clk_i,
            .rst_ni,
            .clr_i (1'b0),
            .rr_i  ('0),
            .req_i (eligible),
            .gnt_o (),
            .data_i('0),
            .req_o (offered[o]),
            .gnt_i (pass_taken[k][o]),
            .data_o(),
            .idx_o (chosen[o])
        );

      end else begin : gen_absent
        assign offered[o] = 1'b0;
        assign chosen[o]  = '0;
      end
    end

    // -- phase two: each free input accepts one output -------------------------
    //
    // Necessary because a payload memory has one read port, and it brings a
    // starvation mode of its own: an input that always favoured the same output
    // would hold up its other queues while they were eligible.
    for (genvar p = 0; p < Ports; p++) begin : gen_input_arb
      if (PortEnable[p]) begin : gen_present
        logic [Ports-1:0] wanted_by;
        for (genvar o = 0; o < Ports; o++) begin : gen_wanted
          assign wanted_by[o] = offered[o] & (chosen[o] == PortIdxWidth'(p)) & input_free[k][p];
        end

        cc_rr_arb_tree #(
            .NumIn    (Ports),
            .DataWidth(1),
            .AxiVldRdy(1'b1)
        ) i_arb (
            .clk_i,
            .rst_ni,
            .clr_i (1'b0),
            .rr_i  ('0),
            .req_i (wanted_by),
            .gnt_o (accepted[p]),
            .data_i('0),
            .req_o (pass_pop[k][p]),
            // Eligibility already reserved a credit, so what is picked is taken.
            .gnt_i (1'b1),
            .data_o(),
            .idx_o (pass_pop_port[k][p])
        );

      end else begin : gen_absent
        assign accepted[p]         = '0;
        assign pass_pop[k][p]      = 1'b0;
        assign pass_pop_port[k][p] = '0;
      end
    end

    for (genvar o = 0; o < Ports; o++) begin : gen_pass_taken
      logic [Ports-1:0] by;
      for (genvar p = 0; p < Ports; p++) begin : gen_by
        assign by[p] = accepted[p][o];
      end
      assign pass_taken[k][o]  = |by;
      assign pass_chosen[k][o] = chosen[o];
    end

    assign input_free[k+1]  = input_free[k] & ~pass_pop[k];
    assign output_free[k+1] = output_free[k] & ~pass_taken[k];
  end

  // At most one pass matches any given port, so combining is an OR.
  always_comb begin
    taken      = '0;
    chosen_idx = '0;
    pop        = '0;
    pop_port   = '0;
    for (int unsigned k = 0; k < MatchIterations; k++) begin
      for (int unsigned o = 0; o < Ports; o++) begin
        if (pass_taken[k][o]) begin
          taken[o]      = 1'b1;
          chosen_idx[o] = pass_chosen[k][o];
        end
      end
      for (int unsigned p = 0; p < Ports; p++) begin
        if (pass_pop[k][p]) begin
          pop[p]      = 1'b1;
          pop_port[p] = pass_pop_port[k][p];
        end
      end
    end
  end

  ////////////////////////////////////////////////////////////////////////////////////////////////
  // The commitment, and the flit that follows it a cycle later
  ////////////////////////////////////////////////////////////////////////////////////////////////

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      committed_q      <= '0;
      committed_from_q <= '0;
    end else begin
      for (int unsigned o = 0; o < Ports; o++) begin
        committed_q[o] <= taken[o];
        if (taken[o]) committed_from_q[o] <= chosen_idx[o];
      end
    end
  end

  for (genvar o = 0; o < Ports; o++) begin : gen_output
    if (PortEnable[o]) begin : gen_present
      chi_link_tx_channel #(
          .FlitWidth(FlitWidth)
      ) i_tx (
          .clk_i,
          .rst_ni,
          .state_i   (link_state),
          // The crossbar: this output's committed input, out of that input's
          // payload memory, which registered it last cycle.
          .flit_i    (pop_flit[committed_from_q[o]]),
          .valid_i   (committed_q[o]),
          // A credit was reserved before the read was committed, so this is
          // never low while `committed_q` is high; the assertion below says so.
          .ready_o   (),
          .flitpend_o(tx_flitpend_o[o]),
          .flitv_o   (tx_flitv_o[o]),
          .flit_o    (tx_flit_o[o]),
          .lcrdv_i   (tx_lcrdv_i[o]),
          .credits_o (tx_credits[o])
      );

    end else begin : gen_absent
      assign tx_flitpend_o[o] = 1'b0;
      assign tx_flitv_o[o]    = 1'b0;
      assign tx_flit_o[o]     = '0;
      assign tx_credits[o]    = '0;
    end
  end

  ////////////////////////////////////////////////////////////////////////////////////////////////
  // What must never happen
  //
  // Immediate assertions in clocked blocks rather than concurrent SVA: only a
  // subset of the latter is supported by the simulator this has to run under
  // first, which is the same reasoning //hardware/vip/README.md gives. Each has
  // a test that makes it fire; an assertion nobody has watched fail is
  // decoration.
  ////////////////////////////////////////////////////////////////////////////////////////////////

  for (genvar p = 0; p < Ports; p++) begin : gen_checks
    if (PortEnable[p]) begin : gen_present

      // Checked as a flit arrives rather than as it leaves, which is earlier
      // and is the only moment its destination is still a computation rather
      // than a queue it is already standing in.
      for (genvar o = 0; o < Ports; o++) begin : gen_turn
        if (!chi_noc_pkg::chi_xp_turn_legal(p, o)) begin : gen_illegal
          always_ff @(posedge clk_i) begin
            if (rst_ni) begin
              assert (!(arriving[p] && arriving_dest[p][o]))
              else
                $fatal(1, "chi_xp_channel(%0d,%0d): flit from port %0d took the illegal turn to %0d",
                       XIndex, YIndex, p, o);
            end
          end
        end
      end

      always_ff @(posedge clk_i) begin
        if (rst_ni) begin
          // Addressed to a port this crosspoint does not have: a target off the
          // mesh, or a device port with nothing on it. There is no queue to
          // join, so the flit would be lost rather than merely stuck.
          assert (!(arriving[p] && ((arriving_dest[p] & PortEnable) == '0)))
          else
            $fatal(1, "chi_xp_channel(%0d,%0d): flit from port %0d addressed to a disabled port",
                   XIndex, YIndex, p);
        end
      end

      // An input holding something to send and sending nothing. Round-robin
      // bounds the wait against other inputs and against this input's own other
      // queues; nothing bounds it against a higher QoS class, which CHI permits
      // and a machine still does not want. This does not prove the bound -- it
      // notices when one is exceeded, which turns a hang into a message naming
      // the port.
      localparam int unsigned StallWidth = $clog2(StarvationLimit + 1);
      logic [StallWidth-1:0] stalled_q;

      always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) stalled_q <= '0;
        else if (|head_valid[p] && !pop[p]) stalled_q <= stalled_q + 1'b1;
        else stalled_q <= '0;
      end

      always_ff @(posedge clk_i) begin
        if (rst_ni) begin
          assert (stalled_q < StallWidth'(StarvationLimit))
          else
            $fatal(1, "chi_xp_channel(%0d,%0d): port %0d unserved for %0d cycles",
                   XIndex, YIndex, p, StarvationLimit);
        end
      end
    end
  end

  // The reservation, checked rather than assumed. A committed read reaching a
  // transmitter with no credit means the arithmetic in `credit_ok` is wrong,
  // and the flit would be dropped with nothing else to notice.
  for (genvar o = 0; o < Ports; o++) begin : gen_reservation
    if (PortEnable[o]) begin : gen_present
      always_ff @(posedge clk_i) begin
        if (rst_ni) begin
          assert (!(committed_q[o] && (tx_credits[o] == '0)))
          else
            $fatal(1, "chi_xp_channel(%0d,%0d): output %0d holds a flit and no credit to send it",
                   XIndex, YIndex, o);
        end
      end
    end
  end

  // Elaboration-time checks on the five numbers, because a wrong one is a
  // silent misroute rather than a build failure.
  if (TgtIdWidth != chi_noc_pkg::CHI_NOC_NODEID_WIDTH) begin : gen_bad_tgtid
    $fatal(1, "chi_xp_channel: TgtIdWidth must match chi_noc_pkg's NodeID width");
  end
  if (TgtIdOffset + TgtIdWidth > FlitWidth) begin : gen_tgtid_off_end
    $fatal(1, "chi_xp_channel: TgtID does not fit inside the flit");
  end
  if (QosWidth < PrioBits) begin : gen_qos_too_narrow
    $fatal(1, "chi_xp_channel: QoS is narrower than the priority classes it must hold");
  end

endmodule
