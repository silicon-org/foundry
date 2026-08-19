// One CHI channel, transmitting: valid/ready in, L-Credits and a flit out.
//
// CHI's flow control is not valid/ready and the difference is the whole reason
// this module exists. A transmitter may send a flit only when it holds an
// L-Credit; the receiver grants credits by pulsing LCRDV, unprompted, and there
// is no ready to push back with. So a transmitter is a credit counter and a
// register, and everything upstream of it can go on speaking valid/ready.
//
// Parameterised by flit width rather than by flit type, so that one module
// serves REQ, RSP, DAT and SNP. Nothing here looks inside a flit -- except for
// the L-Credit return, which is opcode zero on every channel and which the
// receiving end filters out. See //hardware/vip/README.md for why the interface
// and the protocol are kept apart like this.
module chi_link_tx_channel #(
  parameter int unsigned FlitWidth = 1,

  // Credits this transmitter is prepared to hold. The specification caps a
  // receiver at 15 outstanding, so accepting more than that means the receiver
  // is broken and the assertion below says so rather than silently wrapping.
  parameter int unsigned MaxCredits = chi_pkg::CHI_MAX_LCREDITS
) (
  input  logic clk_i,
  input  logic rst_ni,

  // Which of the four link states this direction is in. Flits move only in RUN;
  // credits are accepted in every state but STOP.
  input  chi_pkg::chi_link_state_e state_i,

  // Inward, valid/ready.
  input  logic [FlitWidth-1:0] flit_i,
  input  logic                 valid_i,
  output logic                 ready_o,

  // Outward, to the pins.
  output logic                 flitpend_o,
  output logic                 flitv_o,
  output logic [FlitWidth-1:0] flit_o,
  input  logic                 lcrdv_i,

  // Credits held but not spent. Deactivation may not complete until this is
  // zero, and the link's own state machine is what watches it.
  output logic [$clog2(MaxCredits+1)-1:0] credits_o
);

  localparam int unsigned CreditWidth = $clog2(MaxCredits + 1);

  logic [CreditWidth-1:0] credits_q;

  // A credit granted while the link is stopped is not ours to keep: the
  // receiver's own counters are reset there too, so counting it would leave the
  // two ends disagreeing for the rest of the run.
  logic accept_credit;
  assign accept_credit = lcrdv_i && (state_i != chi_pkg::CHI_LINK_STOP);

  // In ACTIVATE the link is up but not yet running, so credits accumulate and
  // nothing is sent.
  logic can_send;
  assign can_send = (state_i == chi_pkg::CHI_LINK_RUN) && (credits_q != '0);

  logic send;
  assign send    = valid_i && can_send;
  assign ready_o = can_send;

  // Deactivation is not finished until every credit has been given back, and
  // the only way back is a flit: opcode zero on any channel is an L-Credit
  // return. So a deactivating transmitter with nothing to say spends its
  // remaining credits on returning them, one per cycle, and the receiver's
  // outstanding count drains to zero. Without this the link reaches DEACTIVATE
  // and stops there, because the receiver may not withdraw its acknowledgement
  // while it is still owed credits.
  logic return_credit;
  assign return_credit =
      (state_i == chi_pkg::CHI_LINK_DEACTIVATE) && !valid_i && (credits_q != '0);

  logic fire;
  assign fire = send || return_credit;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) credits_q <= '0;
    else if (accept_credit && !fire) credits_q <= credits_q + 1'b1;
    else if (fire && !accept_credit) credits_q <= credits_q - 1'b1;
  end

  assign credits_o = credits_q;

  // FLITPEND is an early warning that a flit may follow, for receivers that
  // clock-gate on it. Holding it high is legal and is what XiangShan's own link
  // layer does; a receiver that acts on it gains nothing here and a receiver
  // that ignores it is unaffected.
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) flitpend_o <= 1'b0;
    else flitpend_o <= 1'b1;
  end

  // Registered, because the flit and its valid are what the other end samples
  // and an unregistered path from a credit counter to a 422-bit bus is not
  // something to hand a synthesis tool.
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      flitv_o <= 1'b0;
      flit_o  <= '0;
    end else begin
      flitv_o <= fire;
      // All zeros is an L-Credit return, because opcode zero is and every other
      // field is ignored on one.
      if (fire) flit_o <= send ? flit_i : '0;
    end
  end

  // The receiver has granted more credits than the specification permits it to
  // have outstanding, which means its accounting and ours have diverged.
  always_ff @(posedge clk_i) begin
    if (rst_ni)
      assert (!(accept_credit && !fire && credits_q == MaxCredits[CreditWidth-1:0]))
      else $fatal(1, "chi_link_tx_channel: L-Credit granted with %0d already held", MaxCredits);
  end

endmodule
