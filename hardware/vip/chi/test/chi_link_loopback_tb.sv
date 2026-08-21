// A whole CHI link with no design in it.
//
// chi_link_rn wired to chi_link_hn, both ends' decoupled sides driven from here.
// Everything the link layer does -- credits, activation, deactivation, the
// L-Credit return that is a flit but not a message -- is reachable from this
// testbench in a few tens of cycles, and none of it needs a protocol model or a
// core. That is the point: the credit accounting gets debugged here, in seconds,
// and not against 1868 generated modules where an off-by-one credit looks like a
// coherence bug.
//
// One model, several tests: `+case=` picks which. See BUILD.bazel.

`include "vip_dpi.svh"

module chi_link_loopback_tb #(
  // A half period rather than a period, because `time` is an integer type and
  // `ClkPeriod / 2` is integer division: at a coarse enough time precision it
  // rounds to zero and `forever #0` is an infinite loop in zero time -- which
  // is reported, at some distance from the cause, as an inactive region that
  // would not converge. Naming the half period removes the division and the
  // question.
  parameter time ClkHalfPeriod = 1ns,

  // Small, and deliberately different per channel, so that a credit counter
  // wired to the wrong channel's parameter shows up as a wrong stall point
  // rather than as nothing at all.
  parameter int unsigned ReqCredits = 4,
  parameter int unsigned RspCredits = 3,
  parameter int unsigned DatCredits = 2,
  parameter int unsigned SnpCredits = 5,

  // Long enough for any case here; a case that needs more has hung.
  parameter int unsigned Timeout = 2000
);

  import chi_pkg::*;

  ////////////////////////////////////////////////////////////////////////////////////////////////
  // Clock, reset and the case selector
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

  initial begin
    wait (rst_n);
    repeat (Timeout) @(posedge clk);
    // The flit counts, because a case that hangs is almost always a case waiting
    // on a channel that never delivered, and naming which one saves the next
    // person a waveform.
    $display("timeout: states %s/%s, flits seen req=%0d rsp_up=%0d dat_up=%0d rsp_down=%0d ",
             rn_tx_state.name(), rn_rx_state.name(), req_seen, rsp_up_seen, dat_up_seen,
             rsp_down_seen);
    $display("timeout: dat_down=%0d snp_down=%0d, ready req=%0b rsp_up=%0b dat_up=%0b ",
             dat_down_seen, snp_down_seen, rn_txreq_ready, rn_txrsp_ready, rn_txdat_ready);
    $display("timeout: ready rsp_down=%0b dat_down=%0b snp_down=%0b", hn_txrsp_ready,
             hn_txdat_ready, hn_txsnp_ready);
    $fatal(1, "case %s: %0d cycles and it never finished", test_case, Timeout);
  end

  ////////////////////////////////////////////////////////////////////////////////////////////////
  // The link
  //
  // `rogue` replaces the request node's pins with ones this testbench drives
  // directly, which is the only way to produce something a correct transmitter
  // never would -- a flit with no credit behind it, or an L-Credit return in the
  // middle of a run. An interface checker that has never seen a violation is
  // decoration.
  ////////////////////////////////////////////////////////////////////////////////////////////////

  chi_rn_link_tx_t rn_pins;
  chi_rn_link_tx_t hn_pins_i;
  chi_rn_link_rx_t hn_pins_o;

  // Only the REQ channel is replaced. Overriding the whole bundle would freeze
  // the credits this end grants on the other three, which the far end then
  // reports as an overflow -- a fault, but not the one under test.
  chi_chan_req_t rogue_txreq;
  logic          use_rogue;

  always_comb begin
    hn_pins_i = rn_pins;
    if (use_rogue) hn_pins_i.txreq = rogue_txreq;
  end

  logic rn_deactivate;
  logic hn_deactivate;

  chi_req_t rn_txreq;
  logic     rn_txreq_valid;
  logic     rn_txreq_ready;
  chi_rsp_t rn_txrsp;
  logic     rn_txrsp_valid;
  logic     rn_txrsp_ready;
  chi_dat_t rn_txdat;
  logic     rn_txdat_valid;
  logic     rn_txdat_ready;

  chi_rsp_t rn_rxrsp;
  logic     rn_rxrsp_valid;
  logic     rn_rxrsp_ready;
  chi_dat_t rn_rxdat;
  logic     rn_rxdat_valid;
  logic     rn_rxdat_ready;
  chi_snp_t rn_rxsnp;
  logic     rn_rxsnp_valid;
  logic     rn_rxsnp_ready;

  chi_link_state_e rn_tx_state;
  chi_link_state_e rn_rx_state;

  chi_link_rn #(
    .RspCredits (RspCredits),
    .DatCredits (DatCredits),
    .SnpCredits (SnpCredits)
  ) i_rn (
    .clk_i         (clk),
    .rst_ni        (rst_n),
    .deactivate_i  (rn_deactivate),
    .rn_o          (rn_pins),
    .hn_i          (hn_pins_o),
    .txreq_i       (rn_txreq),
    .txreq_valid_i (rn_txreq_valid),
    .txreq_ready_o (rn_txreq_ready),
    .txrsp_i       (rn_txrsp),
    .txrsp_valid_i (rn_txrsp_valid),
    .txrsp_ready_o (rn_txrsp_ready),
    .txdat_i       (rn_txdat),
    .txdat_valid_i (rn_txdat_valid),
    .txdat_ready_o (rn_txdat_ready),
    .rxrsp_o       (rn_rxrsp),
    .rxrsp_valid_o (rn_rxrsp_valid),
    .rxrsp_ready_i (rn_rxrsp_ready),
    .rxdat_o       (rn_rxdat),
    .rxdat_valid_o (rn_rxdat_valid),
    .rxdat_ready_i (rn_rxdat_ready),
    .rxsnp_o       (rn_rxsnp),
    .rxsnp_valid_o (rn_rxsnp_valid),
    .rxsnp_ready_i (rn_rxsnp_ready),
    .rn_tx_state_o (rn_tx_state),
    .rn_rx_state_o (rn_rx_state)
  );

  chi_req_t hn_rxreq;
  logic     hn_rxreq_valid;
  logic     hn_rxreq_ready;
  chi_rsp_t hn_rxrsp;
  logic     hn_rxrsp_valid;
  logic     hn_rxrsp_ready;
  chi_dat_t hn_rxdat;
  logic     hn_rxdat_valid;
  logic     hn_rxdat_ready;

  chi_rsp_t hn_txrsp;
  logic     hn_txrsp_valid;
  logic     hn_txrsp_ready;
  chi_dat_t hn_txdat;
  logic     hn_txdat_valid;
  logic     hn_txdat_ready;
  chi_snp_t hn_txsnp;
  logic     hn_txsnp_valid;
  logic     hn_txsnp_ready;

  chi_link_state_e hn_rn_tx_state;
  chi_link_state_e hn_rn_rx_state;

  chi_link_hn #(
    .ReqCredits (ReqCredits),
    .RspCredits (RspCredits),
    .DatCredits (DatCredits)
  ) i_hn (
    .clk_i         (clk),
    .rst_ni        (rst_n),
    .deactivate_i  (hn_deactivate),
    .rn_i          (hn_pins_i),
    .hn_o          (hn_pins_o),
    .rxreq_o       (hn_rxreq),
    .rxreq_valid_o (hn_rxreq_valid),
    .rxreq_ready_i (hn_rxreq_ready),
    .rxrsp_o       (hn_rxrsp),
    .rxrsp_valid_o (hn_rxrsp_valid),
    .rxrsp_ready_i (hn_rxrsp_ready),
    .rxdat_o       (hn_rxdat),
    .rxdat_valid_o (hn_rxdat_valid),
    .rxdat_ready_i (hn_rxdat_ready),
    .txrsp_i       (hn_txrsp),
    .txrsp_valid_i (hn_txrsp_valid),
    .txrsp_ready_o (hn_txrsp_ready),
    .txdat_i       (hn_txdat),
    .txdat_valid_i (hn_txdat_valid),
    .txdat_ready_o (hn_txdat_ready),
    .txsnp_i       (hn_txsnp),
    .txsnp_valid_i (hn_txsnp_valid),
    .txsnp_ready_o (hn_txsnp_ready),
    .rn_tx_state_o (hn_rn_tx_state),
    .rn_rx_state_o (hn_rn_rx_state)
  );

  ////////////////////////////////////////////////////////////////////////////////////////////////
  // Both ends read the same two wires per direction, so they must agree on the
  // state at all times. This is the cheapest possible check and it catches a
  // whole class of handshake mistake.
  ////////////////////////////////////////////////////////////////////////////////////////////////

  always_ff @(posedge clk) begin
    if (rst_n && !use_rogue) begin
      assert (rn_tx_state == hn_rn_tx_state)
      else
        $error("cycle %0d: the two ends disagree about the RN's transmit link: %s and %s", cycle,
               rn_tx_state.name(), hn_rn_tx_state.name());
      assert (rn_rx_state == hn_rn_rx_state)
      else
        $error("cycle %0d: the two ends disagree about the RN's receive link: %s and %s", cycle,
               rn_rx_state.name(), hn_rn_rx_state.name());
    end
  end

  // Nothing may move before the link is running. Checked on the pins rather than
  // on the decoupled side, because this is a property of the link and not of
  // whatever is behind it.
  always_ff @(posedge clk) begin
    if (rst_n && !use_rogue) begin
      assert (!(hn_pins_i.txreq.flitv && rn_tx_state != CHI_LINK_RUN &&
                rn_tx_state != CHI_LINK_DEACTIVATE))
      else $error("cycle %0d: a REQ flit moved in %s", cycle, rn_tx_state.name());
      assert (!(hn_pins_o.rxrsp.flitv && rn_rx_state != CHI_LINK_RUN &&
                rn_rx_state != CHI_LINK_DEACTIVATE))
      else $error("cycle %0d: an RSP flit moved in %s", cycle, rn_rx_state.name());
    end
  end

  ////////////////////////////////////////////////////////////////////////////////////////////////
  // Drivers
  ////////////////////////////////////////////////////////////////////////////////////////////////

  // Distinct per flit, so that a flit arriving in the wrong order or on the
  // wrong channel is visible in its payload rather than only in its count.
  function automatic chi_req_t make_req(logic [11:0] tag);
    chi_req_t f = '0;
    f.qos    = tag[3:0];
    f.tgt_id = 11'h2A;
    f.src_id = 11'h15;
    f.txn_id = tag;
    f.opcode = CHI_REQ_READ_NOT_SHARED_DIRTY;
    f.size   = 3'd6;
    f.addr   = 48'h8000_0000 + (48'(tag) << 6);
    return f;
  endfunction

  function automatic chi_rsp_t make_rsp(logic [11:0] tag);
    chi_rsp_t f = '0;
    f.qos    = tag[3:0];
    f.tgt_id = 11'h15;
    f.src_id = 11'h2A;
    f.txn_id = tag;
    f.opcode = CHI_RSP_COMP;
    f.resp   = CHI_RESP_UC;
    f.db_id  = tag;
    return f;
  endfunction

  function automatic chi_dat_t make_dat(logic [11:0] tag);
    chi_dat_t f = '0;
    f.qos      = tag[3:0];
    f.tgt_id   = 11'h15;
    f.src_id   = 11'h2A;
    f.txn_id   = tag;
    f.home_nid = 11'h2A;
    f.opcode   = CHI_DAT_COMP_DATA;
    f.resp     = CHI_RESP_UC;
    f.data_id  = 2'd0;
    f.be       = '1;
    f.data     = {8{32'hA5A5_0000 + 32'(tag)}};
    return f;
  endfunction

  function automatic chi_snp_t make_snp(logic [11:0] tag);
    chi_snp_t f = '0;
    f.qos    = tag[3:0];
    f.src_id = 11'h2A;
    f.txn_id = tag;
    f.opcode = CHI_SNP_UNIQUE;
    f.addr   = 45'(48'h8000_0000 >> 3);
    return f;
  endfunction

  ////////////////////////////////////////////////////////////////////////////////////////////////
  // Drivers
  //
  // Stimulus is driven on the falling edge and handshakes are observed on the
  // falling edge after the rising one that decided them. Both halves of that
  // matter. Driving on the rising edge races the design, which samples there;
  // and reading `ready` from a procedural block after a rising edge reads it
  // *after* the design's own registers have updated, so a transmitter that was
  // not ready at the edge looks ready just afterwards -- which is how a flit
  // gets dropped by a testbench that thinks it sent one.
  ////////////////////////////////////////////////////////////////////////////////////////////////

  logic rn_txreq_fired;
  logic rn_txrsp_fired;
  logic rn_txdat_fired;
  logic hn_txrsp_fired;
  logic hn_txdat_fired;
  logic hn_txsnp_fired;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rn_txreq_fired <= 1'b0;
      rn_txrsp_fired <= 1'b0;
      rn_txdat_fired <= 1'b0;
      hn_txrsp_fired <= 1'b0;
      hn_txdat_fired <= 1'b0;
      hn_txsnp_fired <= 1'b0;
    end else begin
      rn_txreq_fired <= rn_txreq_valid && rn_txreq_ready;
      rn_txrsp_fired <= rn_txrsp_valid && rn_txrsp_ready;
      rn_txdat_fired <= rn_txdat_valid && rn_txdat_ready;
      hn_txrsp_fired <= hn_txrsp_valid && hn_txrsp_ready;
      hn_txdat_fired <= hn_txdat_valid && hn_txdat_ready;
      hn_txsnp_fired <= hn_txsnp_valid && hn_txsnp_ready;
    end
  end

  // Everything the tests do to a channel, in one place, so a case reads as a
  // sequence of intentions.
  task automatic send_req(logic [11:0] tag);
    @(negedge clk);
    rn_txreq       = make_req(tag);
    rn_txreq_valid = 1'b1;
    do @(negedge clk); while (!rn_txreq_fired);
    rn_txreq_valid = 1'b0;
  endtask

  task automatic send_rsp_up(logic [11:0] tag);
    @(negedge clk);
    rn_txrsp       = make_rsp(tag);
    rn_txrsp_valid = 1'b1;
    do @(negedge clk); while (!rn_txrsp_fired);
    rn_txrsp_valid = 1'b0;
  endtask

  task automatic send_dat_up(logic [11:0] tag);
    @(negedge clk);
    rn_txdat       = make_dat(tag);
    rn_txdat_valid = 1'b1;
    do @(negedge clk); while (!rn_txdat_fired);
    rn_txdat_valid = 1'b0;
  endtask

  task automatic send_rsp_down(logic [11:0] tag);
    @(negedge clk);
    hn_txrsp       = make_rsp(tag);
    hn_txrsp_valid = 1'b1;
    do @(negedge clk); while (!hn_txrsp_fired);
    hn_txrsp_valid = 1'b0;
  endtask

  task automatic send_dat_down(logic [11:0] tag);
    @(negedge clk);
    hn_txdat       = make_dat(tag);
    hn_txdat_valid = 1'b1;
    do @(negedge clk); while (!hn_txdat_fired);
    hn_txdat_valid = 1'b0;
  endtask

  task automatic send_snp_down(logic [11:0] tag);
    @(negedge clk);
    hn_txsnp       = make_snp(tag);
    hn_txsnp_valid = 1'b1;
    do @(negedge clk); while (!hn_txsnp_fired);
    hn_txsnp_valid = 1'b0;
  endtask

  task automatic await_running();
    while (rn_tx_state != CHI_LINK_RUN || rn_rx_state != CHI_LINK_RUN) @(posedge clk);
  endtask

  ////////////////////////////////////////////////////////////////////////////////////////////////
  // Receivers
  //
  // Both ends accept everything, and record what they saw. Held ready because
  // this testbench is about flow control on the link and not about back-pressure
  // behind it; the buffer in each receiving channel is exercised by the flood
  // case, where credits outrun the far end's willingness to send.
  ////////////////////////////////////////////////////////////////////////////////////////////////

  int unsigned req_seen;
  int unsigned rsp_up_seen;
  int unsigned dat_up_seen;
  int unsigned rsp_down_seen;
  int unsigned dat_down_seen;
  int unsigned snp_down_seen;

  chi_req_t last_req;
  chi_rsp_t last_rsp_up;
  chi_dat_t last_dat_up;
  chi_rsp_t last_rsp_down;
  chi_dat_t last_dat_down;
  chi_snp_t last_snp_down;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      req_seen      <= 0;
      rsp_up_seen   <= 0;
      dat_up_seen   <= 0;
      rsp_down_seen <= 0;
      dat_down_seen <= 0;
      snp_down_seen <= 0;
    end else begin
      if (hn_rxreq_valid && hn_rxreq_ready) begin
        req_seen <= req_seen + 1;
        last_req <= hn_rxreq;
      end
      if (hn_rxrsp_valid && hn_rxrsp_ready) begin
        rsp_up_seen <= rsp_up_seen + 1;
        last_rsp_up <= hn_rxrsp;
      end
      if (hn_rxdat_valid && hn_rxdat_ready) begin
        dat_up_seen <= dat_up_seen + 1;
        last_dat_up <= hn_rxdat;
      end
      if (rn_rxrsp_valid && rn_rxrsp_ready) begin
        rsp_down_seen <= rsp_down_seen + 1;
        last_rsp_down <= rn_rxrsp;
      end
      if (rn_rxdat_valid && rn_rxdat_ready) begin
        dat_down_seen <= dat_down_seen + 1;
        last_dat_down <= rn_rxdat;
      end
      if (rn_rxsnp_valid && rn_rxsnp_ready) begin
        snp_down_seen <= snp_down_seen + 1;
        last_snp_down <= rn_rxsnp;
      end
    end
  end

  ////////////////////////////////////////////////////////////////////////////////////////////////
  // The cases
  ////////////////////////////////////////////////////////////////////////////////////////////////

  // Both links come up from reset with nobody asking them to, credits appear,
  // and no flit moves before RUN. The assertions above do most of the work; what
  // this adds is that it happens at all, and promptly.
  task automatic case_bringup();
    await_running();
    assert (cycle < 32)
    else $error("the link took %0d cycles to reach RUN", cycle);
    // Credits have to arrive before anything can be sent, and readiness on the
    // decoupled side is how a transmitter says it holds one.
    while (!rn_txreq_ready || !hn_txrsp_ready) @(posedge clk);
    $display("bringup: RUN at cycle %0d, credits granted both ways", cycle);
  endtask

  // One flit each way on every channel, with its payload checked at the far
  // end. Six flits, six channels, and any pair of channels crossed shows up as
  // a payload that does not match.
  task automatic case_transfer();
    await_running();
    send_req(1);
    send_rsp_up(2);
    send_dat_up(3);
    send_rsp_down(4);
    send_dat_down(5);
    send_snp_down(6);

    while (req_seen == 0 || rsp_up_seen == 0 || dat_up_seen == 0 || rsp_down_seen == 0 ||
           dat_down_seen == 0 || snp_down_seen == 0)
      @(posedge clk);

    assert (last_req == make_req(1)) else $error("REQ arrived changed");
    assert (last_rsp_up == make_rsp(2)) else $error("upstream RSP arrived changed");
    assert (last_dat_up == make_dat(3)) else $error("upstream DAT arrived changed");
    assert (last_rsp_down == make_rsp(4)) else $error("downstream RSP arrived changed");
    assert (last_dat_down == make_dat(5)) else $error("downstream DAT arrived changed");
    assert (last_snp_down == make_snp(6)) else $error("downstream SNP arrived changed");
    $display("transfer: six flits, six channels, payloads intact");
  endtask

  // Send until the credits run out, and confirm the transmitter stalls rather
  // than overrunning -- then that it resumes as credits come back. This is the
  // case that would catch a credit counter that never decrements, which is
  // otherwise invisible: everything works, right up to the point where the
  // receiver is overrun.
  task automatic case_credit_exhaustion();
    int unsigned stalls;
    int unsigned sent;
    await_running();

    // Hold the receiving end off so the buffer fills and no credit can be
    // replenished, then push without pause.
    @(negedge clk);
    hn_rxreq_ready = 1'b0;

    rn_txreq       = make_req(12'd0);
    rn_txreq_valid = 1'b1;

    stalls = 0;
    sent   = 0;
    for (int unsigned i = 0; i < ReqCredits + 8; i++) begin
      @(negedge clk);
      if (rn_txreq_fired) begin
        sent = sent + 1;
        rn_txreq = make_req(12'(sent));
      end else begin
        stalls = stalls + 1;
      end
    end
    rn_txreq_valid = 1'b0;

    assert (stalls > 0)
    else
      $error("%0d credits, %0d flits sent, and the transmitter never stalled -- nothing is ",
             ReqCredits, sent);
    assert (sent <= ReqCredits)
    else
      $error("%0d flits went out on %0d credits", sent, ReqCredits);

    // Let the receiver drain; the transmitter must come back.
    @(negedge clk);
    hn_rxreq_ready = 1'b1;
    rn_txreq       = make_req(12'h99);
    rn_txreq_valid = 1'b1;
    do @(negedge clk); while (!rn_txreq_fired);
    rn_txreq_valid = 1'b0;

    $display("credit: %0d flits on %0d credits, stalled %0d cycles, then resumed", sent,
             ReqCredits, stalls);
  endtask

  // Bring the link down. Deactivation only completes when every credit has been
  // returned, and the only way back is an L-Credit return flit -- so this case
  // is the one that exercises a flit that is flow control rather than a message,
  // and it hangs if that path is missing.
  task automatic case_deactivate();
    await_running();
    // A flit first, so there is real traffic to drain rather than an empty link.
    send_req(7);
    while (req_seen == 0) @(posedge clk);

    @(negedge clk);
    rn_deactivate = 1'b1;
    while (rn_tx_state != CHI_LINK_STOP) @(posedge clk);

    // The L-Credit returns must not have been mistaken for requests.
    assert (req_seen == 1)
    else $error("%0d requests seen after deactivation, expected 1 -- credit returns leaked", req_seen);

    $display("deactivate: STOP at cycle %0d, %0d requests seen", cycle, req_seen);
  endtask

  ////////////////////////////////////////////////////////////////////////////////////////////////
  // The negative cases
  //
  // Each drives the pins directly with something no correct transmitter would
  // produce, and each must make the receiving channel complain. A test that
  // expects failure is a shell test in BUILD.bazel, because a passing run here
  // means the check did not fire.
  ////////////////////////////////////////////////////////////////////////////////////////////////

  // More flits than the receiver ever granted credits for. Which invariant
  // notices depends on where the accounting is kept, and here it is the buffer:
  // a credit is a promise of a place to put a flit, so the promises run out at
  // the same moment the places do.
  task automatic case_rogue_overrun();
    await_running();

    @(negedge clk);
    // Stop the receiver draining, so its buffer fills and it stops granting.
    // Without this it hands out a fresh credit every cycle and there is no
    // number of flits that outruns it.
    hn_rxreq_ready = 1'b0;
    rogue_txreq    = rn_pins.txreq;
    use_rogue      = 1'b1;

    // More flits than the receiver ever offered credits for. The first few are
    // legitimate; the ones after the buffer fills are the violation.
    for (int unsigned i = 0; i < ReqCredits + 4; i++) begin
      rogue_txreq.flitpend = 1'b1;
      rogue_txreq.flitv    = 1'b1;
      rogue_txreq.flit     = make_req(12'(i));
      @(negedge clk);
    end
    rogue_txreq.flitv = 1'b0;
    repeat (4) @(negedge clk);

    // Printed unconditionally. Reaching this line is not the case passing --
    // the receiver was supposed to object, and expect_failure.sh is what turns
    // a quiet run into a failure.
    $display("rogue_overrun: ran to the end; the receiver's verdict is the exit status");
  endtask

  // A flit before the link is running, when no credit has been granted at all.
  // The same rule as above, reached from the other side: here there are places
  // in the buffer but no promise attached to any of them.
  task automatic case_rogue_before_run();
    @(negedge clk);
    rogue_txreq          = '0;
    rogue_txreq.flitpend = 1'b1;
    rogue_txreq.flitv    = 1'b1;
    rogue_txreq.flit     = make_req(12'd1);
    use_rogue            = 1'b1;
    repeat (4) @(negedge clk);
    rogue_txreq.flitv = 1'b0;
    repeat (4) @(negedge clk);

    $display("rogue_before_run: ran to the end; the receiver's verdict is the exit status");
  endtask

  ////////////////////////////////////////////////////////////////////////////////////////////////
  // Sequencing
  ////////////////////////////////////////////////////////////////////////////////////////////////

  initial begin
    rn_txreq       = '0;
    rn_txreq_valid = 1'b0;
    rn_txrsp       = '0;
    rn_txrsp_valid = 1'b0;
    rn_txdat       = '0;
    rn_txdat_valid = 1'b0;
    hn_txrsp       = '0;
    hn_txrsp_valid = 1'b0;
    hn_txdat       = '0;
    hn_txdat_valid = 1'b0;
    hn_txsnp       = '0;
    hn_txsnp_valid = 1'b0;

    hn_rxreq_ready = 1'b1;
    hn_rxrsp_ready = 1'b1;
    hn_rxdat_ready = 1'b1;
    rn_rxrsp_ready = 1'b1;
    rn_rxdat_ready = 1'b1;
    rn_rxsnp_ready = 1'b1;

    rn_deactivate = 1'b0;
    hn_deactivate = 1'b0;
    use_rogue     = 1'b0;
    rogue_txreq   = '0;

    wait (rst_n);
    @(posedge clk);

    case (test_case)
      "bringup":          case_bringup();
      "transfer":         case_transfer();
      "credit":           case_credit_exhaustion();
      "deactivate":       case_deactivate();
      "rogue_overrun":     case_rogue_overrun();
      "rogue_before_run":  case_rogue_before_run();
      default: $fatal(1, "unknown case '%s'", test_case);
    endcase

    repeat (4) @(posedge clk);
    vip_test_pass($sformatf("case %s ran to its end", test_case));

    // A generated main() always returns zero, so $fatal here is the only thing
    // that can fail this test.
    assert (!vip_test_failed())
    else $fatal(1, "case %s failed", test_case);
    $finish;
  end

endmodule
