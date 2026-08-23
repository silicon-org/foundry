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
// The shape is OpenNoC's chi_xp_channel generalised: credit-buffered inputs, a
// route per input, and a QoS-aware round-robin per output.
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

    // Buffer depth per input port, and so also the L-Credits granted for it --
    // in a credit-based receiver those are one number, because a credit is the
    // promise of somewhere to put the flit it will bring.
    //
    // Four sustains a flit per cycle at the per-stage budget the README sets
    // out: a credit takes three cycles to come back, so three would just keep
    // up and four has one to spare.
    parameter int unsigned Credits = 4,

    // QoS priority classes, taken from the top bits of QoS. Four is OpenNoC's
    // choice and CHI's intent.
    parameter int unsigned PrioBits = 2,

    // Cycles an input may sit unserved before something is structurally wrong.
    // Arbitration is round-robin within a class, so a bounded wait is a property
    // this module has and should be made to prove; see the assertion below for
    // what it does and does not catch.
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

  // Mesh links never power down: the LINKACTIVE handshake exists for a link to a
  // device that may go away, and both ends of a link inside the fabric come out
  // of the same reset. A device-facing port that needs activation gets it at the
  // boundary, in the agent, rather than in every crosspoint in the mesh.
  chi_pkg::chi_link_state_e link_state;
  assign link_state = chi_pkg::CHI_LINK_RUN;

  ////////////////////////////////////////////////////////////////////////////////////////////////
  // Inputs
  //
  // Each port's receiver is the buffer *and* the credit accounting, because in
  // CHI they are one mechanism. What comes out is ordinary valid/ready, and
  // everything below this line speaks that.
  ////////////////////////////////////////////////////////////////////////////////////////////////

  logic [Ports-1:0]                in_valid;
  logic [Ports-1:0]                in_ready;
  logic [Ports-1:0][FlitWidth-1:0] in_flit;

  // Where each head flit wants to go, one-hot, and how urgently.
  chi_noc_pkg::chi_xp_port_mask_t [Ports-1:0] in_dest;
  logic [Ports-1:0][PrioBits-1:0]             in_prio;

  for (genvar p = 0; p < Ports; p++) begin : gen_input
    if (PortEnable[p]) begin : gen_present
      chi_link_rx_channel #(
          .FlitWidth(FlitWidth),
          .Credits  (Credits)
      ) i_rx (
          .clk_i,
          .rst_ni,
          .state_i         (link_state),
          .flitpend_i      (1'b1),
          .flitv_i         (rx_flitv_i[p]),
          .flit_i          (rx_flit_i[p]),
          .is_lcrd_return_i(rx_is_lcrd_return_i[p]),
          .lcrdv_o         (rx_lcrdv_o[p]),
          .flit_o          (in_flit[p]),
          .valid_o         (in_valid[p]),
          .ready_i         (in_ready[p]),
          // The link's own state machine watches this; here the link never
          // deactivates, so nothing does.
          .outstanding_o   ()
      );

      assign in_dest[p] = chi_noc_pkg::chi_xp_route(
          chi_noc_pkg::chi_noc_x_t'(XIndex),
          chi_noc_pkg::chi_noc_y_t'(YIndex),
          chi_noc_pkg::chi_noc_nodeid_t'(in_flit[p][TgtIdOffset+:TgtIdWidth])
      );

      // The top bits of QoS. CHI's sixteen levels collapse to four classes,
      // which is what the arbiters below distinguish.
      assign in_prio[p] = in_flit[p][QosOffset+QosWidth-PrioBits+:PrioBits];

    end else begin : gen_absent
      assign rx_lcrdv_o[p] = 1'b0;
      assign in_valid[p]   = 1'b0;
      assign in_flit[p]    = '0;
      assign in_dest[p]    = '0;
      assign in_prio[p]    = '0;
    end
  end

  ////////////////////////////////////////////////////////////////////////////////////////////////
  // The crossbar
  //
  // One arbiter per output over every input that wants it. Round-robin, so no
  // input can be starved by its neighbours; QoS first, so a high-priority flit
  // overtakes -- which means a low-priority one *can* be starved by sustained
  // high-priority traffic. CHI permits that; the counter at the bottom of this
  // file is what stops it being invisible.
  ////////////////////////////////////////////////////////////////////////////////////////////////

  logic [Ports-1:0][Ports-1:0] grant;  // [output][input]

  for (genvar o = 0; o < Ports; o++) begin : gen_output
    if (PortEnable[o]) begin : gen_present
      logic [Ports-1:0] request;
      for (genvar p = 0; p < Ports; p++) begin : gen_request
        assign request[p] = in_valid[p] & in_dest[p][o];
      end

      // The highest class asking for this output, and then only those asking at
      // it. Written as a loop rather than a reduction so that adding a class is
      // changing a number.
      logic [PrioBits-1:0] top_prio;
      always_comb begin
        top_prio = '0;
        for (int unsigned p = 0; p < Ports; p++) begin
          if (request[p] && (in_prio[p] > top_prio)) top_prio = in_prio[p];
        end
      end

      logic [Ports-1:0] eligible;
      for (genvar p = 0; p < Ports; p++) begin : gen_eligible
        assign eligible[p] = request[p] & (in_prio[p] == top_prio);
      end

      logic                 out_valid;
      logic                 out_ready;
      logic [FlitWidth-1:0] out_flit;

      cc_rr_arb_tree #(
          .NumIn    (Ports),
          .DataWidth(FlitWidth),
          // The handshake below is valid/ready: `eligible` is computed from
          // buffered flits and never from the grant, which is what this permits
          // the arbiter to assume.
          .AxiVldRdy(1'b1)
      ) i_arb (
          .clk_i,
          .rst_ni,
          .clr_i (1'b0),
          .rr_i  ('0),
          .req_i (eligible),
          .gnt_o (grant[o]),
          .data_i(in_flit),
          .req_o (out_valid),
          .gnt_i (out_ready),
          .data_o(out_flit),
          .idx_o ()
      );

      chi_link_tx_channel #(
          .FlitWidth(FlitWidth)
      ) i_tx (
          .clk_i,
          .rst_ni,
          .state_i   (link_state),
          .flit_i    (out_flit),
          .valid_i   (out_valid),
          .ready_o   (out_ready),
          .flitpend_o(tx_flitpend_o[o]),
          .flitv_o   (tx_flitv_o[o]),
          .flit_o    (tx_flit_o[o]),
          .lcrdv_i   (tx_lcrdv_i[o]),
          .credits_o ()
      );

    end else begin : gen_absent
      assign grant[o]         = '0;
      assign tx_flitpend_o[o] = 1'b0;
      assign tx_flitv_o[o]    = 1'b0;
      assign tx_flit_o[o]     = '0;
    end
  end

  // An input is served when whichever output it asked for grants it. Its
  // destination is one-hot, so at most one term is ever set.
  for (genvar p = 0; p < Ports; p++) begin : gen_ready
    logic [Ports-1:0] granted_by;
    for (genvar o = 0; o < Ports; o++) begin : gen_by
      assign granted_by[o] = grant[o][p];
    end
    assign in_ready[p] = |granted_by;
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

      // The turns dimension-order routing does not have. Asking for one means
      // the flit was misrouted upstream, and a cycle in the channel dependency
      // graph is a deadlock rather than a wrong answer.
      for (genvar o = 0; o < Ports; o++) begin : gen_turn
        if (!chi_noc_pkg::chi_xp_turn_legal(p, o)) begin : gen_illegal
          always_ff @(posedge clk_i) begin
            if (rst_ni) begin
              assert (!(in_valid[p] && in_dest[p][o]))
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
          // mesh, or a device port with nothing on it. There is nowhere to put
          // the flit, so it would sit at the head of this input for ever and
          // block everything behind it.
          assert (!(in_valid[p] && ((in_dest[p] & PortEnable) == '0)))
          else
            $fatal(1, "chi_xp_channel(%0d,%0d): flit from port %0d addressed to a disabled port",
                   XIndex, YIndex, p);

        end
      end

      // Round-robin gives a bounded wait against other inputs, but nothing
      // bounds the wait against a higher QoS class -- CHI permits that, and a
      // fabric that livelocks a low-priority request is still a broken machine.
      // This does not prove the bound; it notices when it is exceeded, which is
      // what turns a hang into a message naming the port.
      localparam int unsigned StallWidth = $clog2(StarvationLimit + 1);
      logic [StallWidth-1:0] stalled_q;

      always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) stalled_q <= '0;
        else if (in_valid[p] && !in_ready[p]) stalled_q <= stalled_q + 1'b1;
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
