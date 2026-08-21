// The home node's end of a CHI link.
//
// Everything about moving flits and nothing about what is in them: this module
// counts L-Credits, works the LINKACTIVE handshake, and presents the six
// channels as valid/ready. It never reads an opcode except to recognise the
// L-Credit return, which is flow control rather than a message.
//
// That division is the point. A home node's *behaviour* -- what a
// ReadNotSharedDirty means, which response is legal, where the data comes from
// -- is C++ on the far side of a DPI boundary, simulator-independent and
// testable with no RTL at all. This module is the interface, and it is testable
// with no protocol at all: chi_link_rn is its mirror, and the two are wired
// together in test/chi_link_loopback_tb.sv with nothing else in the build.
//
// See //hardware/vip/README.md.
module chi_link_hn #(
  // Credits granted on each inbound channel, and so also the depth of the
  // buffer behind it. XiangShan's L2 grants 15 on RSP and DAT and 4 on SNP;
  // there is no requirement to match it, only to stay within the 15 the
  // specification permits.
  parameter int unsigned ReqCredits = 4,
  parameter int unsigned RspCredits = 4,
  parameter int unsigned DatCredits = 4
) (
  input  logic clk_i,
  input  logic rst_ni,

  // Bring this node's transmit link down again. Exposed rather than tied off
  // because a link that can only be brought up has a deactivation path nobody
  // has ever run; test/chi_link_loopback_tb.sv runs it.
  input  logic deactivate_i,

  ////////////////////////////////////////////////////////////////////////////////////////////////
  // The pins, named for who drives them rather than for which way they point.
  ////////////////////////////////////////////////////////////////////////////////////////////////

  input  chi_pkg::chi_rn_link_tx_t rn_i,
  output chi_pkg::chi_rn_link_rx_t hn_o,

  ////////////////////////////////////////////////////////////////////////////////////////////////
  // Received from the request node.
  ////////////////////////////////////////////////////////////////////////////////////////////////

  output chi_pkg::chi_req_t rxreq_o,
  output logic              rxreq_valid_o,
  input  logic              rxreq_ready_i,

  output chi_pkg::chi_rsp_t rxrsp_o,
  output logic              rxrsp_valid_o,
  input  logic              rxrsp_ready_i,

  output chi_pkg::chi_dat_t rxdat_o,
  output logic              rxdat_valid_o,
  input  logic              rxdat_ready_i,

  ////////////////////////////////////////////////////////////////////////////////////////////////
  // Sent to the request node.
  ////////////////////////////////////////////////////////////////////////////////////////////////

  input  chi_pkg::chi_rsp_t txrsp_i,
  input  logic              txrsp_valid_i,
  output logic              txrsp_ready_o,

  input  chi_pkg::chi_dat_t txdat_i,
  input  logic              txdat_valid_i,
  output logic              txdat_ready_o,

  input  chi_pkg::chi_snp_t txsnp_i,
  input  logic              txsnp_valid_i,
  output logic              txsnp_ready_o,

  ////////////////////////////////////////////////////////////////////////////////////////////////
  // Status, for a testbench to watch and for the checker to gate on.
  ////////////////////////////////////////////////////////////////////////////////////////////////

  // Named for whose link each is, because "transmit" alone is ambiguous with two
  // nodes in the room. rn_tx is REQ, RSP and DAT flowing towards this node;
  // rn_rx is RSP, DAT and SNP flowing away from it.
  output chi_pkg::chi_link_state_e rn_tx_state_o,
  output chi_pkg::chi_link_state_e rn_rx_state_o
);

  ////////////////////////////////////////////////////////////////////////////////////////////////
  // Port and system coherency
  //
  // Both are the same shape: the request node asks and this node agrees. A home
  // node with no reason to refuse is the whole of the policy here, and a home
  // node that needed one would put it in the C++ rather than in this module.
  ////////////////////////////////////////////////////////////////////////////////////////////////

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      hn_o.rxsactive <= 1'b0;
      hn_o.syscoack  <= 1'b0;
    end else begin
      hn_o.rxsactive <= 1'b1;
      hn_o.syscoack  <= rn_i.syscoreq;
    end
  end

  ////////////////////////////////////////////////////////////////////////////////////////////////
  // Link activation
  ////////////////////////////////////////////////////////////////////////////////////////////////

  chi_pkg::chi_link_state_e rn_tx_state;
  chi_pkg::chi_link_state_e rn_rx_state;

  logic [$clog2(ReqCredits+1)-1:0] rxreq_outstanding;
  logic [$clog2(RspCredits+1)-1:0] rxrsp_outstanding;
  logic [$clog2(DatCredits+1)-1:0] rxdat_outstanding;

  // This node granted the credits on the request node's transmit link, so it is
  // this node that must keep acknowledging until they have all come back.
  logic rx_credits_returned;
  assign rx_credits_returned =
      (rxreq_outstanding == '0) && (rxrsp_outstanding == '0) && (rxdat_outstanding == '0);

  chi_link_activation_ack i_rn_tx_activation (
    .clk_i,
    .rst_ni,
    .linkactivereq_i    (rn_i.tx_linkactivereq),
    .linkactiveack_o    (hn_o.tx_linkactiveack),
    .credits_returned_i (rx_credits_returned),
    .state_o            (rn_tx_state)
  );

  chi_link_activation_req i_rn_rx_activation (
    .clk_i,
    .rst_ni,
    .deactivate_i     (deactivate_i),
    .linkactivereq_o  (hn_o.rx_linkactivereq),
    .linkactiveack_i  (rn_i.rx_linkactiveack),
    .state_o          (rn_rx_state)
  );

  assign rn_tx_state_o = rn_tx_state;
  assign rn_rx_state_o = rn_rx_state;

  ////////////////////////////////////////////////////////////////////////////////////////////////
  // Received channels
  //
  ////////////////////////////////////////////////////////////////////////////////////////////////



  chi_link_rx_channel #(
    .FlitWidth ($bits(chi_pkg::chi_req_t)),
    .Credits   (ReqCredits)
  ) i_rxreq (
    .clk_i,
    .rst_ni,
    .state_i          (rn_tx_state),
    .flitpend_i       (rn_i.txreq.flitpend),
    .flitv_i          (rn_i.txreq.flitv),
    .flit_i           (rn_i.txreq.flit),
    .is_lcrd_return_i (chi_pkg::chi_req_is_lcrd_return(rn_i.txreq.flit.opcode)),
    .lcrdv_o          (hn_o.txreq_lcrdv),
    .flit_o           (rxreq_o),
    .valid_o          (rxreq_valid_o),
    .ready_i          (rxreq_ready_i),
    .outstanding_o    (rxreq_outstanding)
  );

  chi_link_rx_channel #(
    .FlitWidth ($bits(chi_pkg::chi_rsp_t)),
    .Credits   (RspCredits)
  ) i_rxrsp (
    .clk_i,
    .rst_ni,
    .state_i          (rn_tx_state),
    .flitpend_i       (rn_i.txrsp.flitpend),
    .flitv_i          (rn_i.txrsp.flitv),
    .flit_i           (rn_i.txrsp.flit),
    .is_lcrd_return_i (chi_pkg::chi_rsp_is_lcrd_return(rn_i.txrsp.flit.opcode)),
    .lcrdv_o          (hn_o.txrsp_lcrdv),
    .flit_o           (rxrsp_o),
    .valid_o          (rxrsp_valid_o),
    .ready_i          (rxrsp_ready_i),
    .outstanding_o    (rxrsp_outstanding)
  );

  chi_link_rx_channel #(
    .FlitWidth ($bits(chi_pkg::chi_dat_t)),
    .Credits   (DatCredits)
  ) i_rxdat (
    .clk_i,
    .rst_ni,
    .state_i          (rn_tx_state),
    .flitpend_i       (rn_i.txdat.flitpend),
    .flitv_i          (rn_i.txdat.flitv),
    .flit_i           (rn_i.txdat.flit),
    .is_lcrd_return_i (chi_pkg::chi_dat_is_lcrd_return(rn_i.txdat.flit.opcode)),
    .lcrdv_o          (hn_o.txdat_lcrdv),
    .flit_o           (rxdat_o),
    .valid_o          (rxdat_valid_o),
    .ready_i          (rxdat_ready_i),
    .outstanding_o    (rxdat_outstanding)
  );

  ////////////////////////////////////////////////////////////////////////////////////////////////
  // Transmitted channels
  ////////////////////////////////////////////////////////////////////////////////////////////////

  logic [$clog2(chi_pkg::CHI_MAX_LCREDITS+1)-1:0] txrsp_credits;
  logic [$clog2(chi_pkg::CHI_MAX_LCREDITS+1)-1:0] txdat_credits;
  logic [$clog2(chi_pkg::CHI_MAX_LCREDITS+1)-1:0] txsnp_credits;

  chi_link_tx_channel #(
    .FlitWidth ($bits(chi_pkg::chi_rsp_t))
  ) i_txrsp (
    .clk_i,
    .rst_ni,
    .state_i    (rn_rx_state),
    .flit_i     (txrsp_i),
    .valid_i    (txrsp_valid_i),
    .ready_o    (txrsp_ready_o),
    .flitpend_o (hn_o.rxrsp.flitpend),
    .flitv_o    (hn_o.rxrsp.flitv),
    .flit_o     (hn_o.rxrsp.flit),
    .lcrdv_i    (rn_i.rxrsp_lcrdv),
    .credits_o  (txrsp_credits)
  );

  chi_link_tx_channel #(
    .FlitWidth ($bits(chi_pkg::chi_dat_t))
  ) i_txdat (
    .clk_i,
    .rst_ni,
    .state_i    (rn_rx_state),
    .flit_i     (txdat_i),
    .valid_i    (txdat_valid_i),
    .ready_o    (txdat_ready_o),
    .flitpend_o (hn_o.rxdat.flitpend),
    .flitv_o    (hn_o.rxdat.flitv),
    .flit_o     (hn_o.rxdat.flit),
    .lcrdv_i    (rn_i.rxdat_lcrdv),
    .credits_o  (txdat_credits)
  );

  chi_link_tx_channel #(
    .FlitWidth ($bits(chi_pkg::chi_snp_t))
  ) i_txsnp (
    .clk_i,
    .rst_ni,
    .state_i    (rn_rx_state),
    .flit_i     (txsnp_i),
    .valid_i    (txsnp_valid_i),
    .ready_o    (txsnp_ready_o),
    .flitpend_o (hn_o.rxsnp.flitpend),
    .flitv_o    (hn_o.rxsnp.flitv),
    .flit_o     (hn_o.rxsnp.flit),
    .lcrdv_i    (rn_i.rxsnp_lcrdv),
    .credits_o  (txsnp_credits)
  );

  // Read only by the assertions inside the channels, and by nothing here.
  logic unused;
  assign unused = ^{txrsp_credits, txdat_credits, txsnp_credits,
                    // TXSACTIVE says the request node's port is powered. A home
                    // node that never powers down has nothing to do with it.
                    rn_i.txsactive};

endmodule
