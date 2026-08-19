// The request node's end of a CHI link: chi_link_hn's mirror image.
//
// Two reasons it exists. The first is immediate: wired to chi_link_hn it makes a
// complete link with no design in it, which is where the credit accounting and
// the activation handshake get debugged -- in seconds, against something whose
// every state is reachable from the testbench, rather than against 1868
// generated modules.
//
// The second is that a request-node agent needs it later. When there is home
// node RTL in this project to verify, this is the end that drives it.
module chi_link_rn #(
  parameter int unsigned RspCredits = 4,
  parameter int unsigned DatCredits = 4,
  parameter int unsigned SnpCredits = 4
) (
  input  logic clk_i,
  input  logic rst_ni,

  // Bring this node's transmit link down again. Exposed rather than tied off
  // because a link that can only be brought up has a deactivation path nobody
  // has ever run; test/chi_link_loopback_tb.sv runs it.
  input  logic deactivate_i,

  output chi_pkg::chi_rn_link_tx_t rn_o,
  input  chi_pkg::chi_rn_link_rx_t hn_i,

  ////////////////////////////////////////////////////////////////////////////////////////////////
  // Sent to the home node.
  ////////////////////////////////////////////////////////////////////////////////////////////////

  input  chi_pkg::chi_req_t txreq_i,
  input  logic              txreq_valid_i,
  output logic              txreq_ready_o,

  input  chi_pkg::chi_rsp_t txrsp_i,
  input  logic              txrsp_valid_i,
  output logic              txrsp_ready_o,

  input  chi_pkg::chi_dat_t txdat_i,
  input  logic              txdat_valid_i,
  output logic              txdat_ready_o,

  ////////////////////////////////////////////////////////////////////////////////////////////////
  // Received from the home node.
  ////////////////////////////////////////////////////////////////////////////////////////////////

  output chi_pkg::chi_rsp_t rxrsp_o,
  output logic              rxrsp_valid_o,
  input  logic              rxrsp_ready_i,

  output chi_pkg::chi_dat_t rxdat_o,
  output logic              rxdat_valid_o,
  input  logic              rxdat_ready_i,

  output chi_pkg::chi_snp_t rxsnp_o,
  output logic              rxsnp_valid_o,
  input  logic              rxsnp_ready_i,

  output chi_pkg::chi_link_state_e rn_tx_state_o,
  output chi_pkg::chi_link_state_e rn_rx_state_o
);

  ////////////////////////////////////////////////////////////////////////////////////////////////
  // Port and system coherency: this end is the one that asks.
  ////////////////////////////////////////////////////////////////////////////////////////////////

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      rn_o.txsactive <= 1'b0;
      rn_o.syscoreq  <= 1'b0;
    end else begin
      rn_o.txsactive <= 1'b1;
      rn_o.syscoreq  <= 1'b1;
    end
  end

  ////////////////////////////////////////////////////////////////////////////////////////////////
  // Link activation
  ////////////////////////////////////////////////////////////////////////////////////////////////

  chi_pkg::chi_link_state_e rn_tx_state;
  chi_pkg::chi_link_state_e rn_rx_state;

  logic [$clog2(RspCredits+1)-1:0] rxrsp_outstanding;
  logic [$clog2(DatCredits+1)-1:0] rxdat_outstanding;
  logic [$clog2(SnpCredits+1)-1:0] rxsnp_outstanding;

  logic rx_credits_returned;
  assign rx_credits_returned =
      (rxrsp_outstanding == '0) && (rxdat_outstanding == '0) && (rxsnp_outstanding == '0);

  chi_link_activation_req i_rn_tx_activation (
    .clk_i,
    .rst_ni,
    .deactivate_i     (deactivate_i),
    .linkactivereq_o  (rn_o.tx_linkactivereq),
    .linkactiveack_i  (hn_i.tx_linkactiveack),
    .state_o          (rn_tx_state)
  );

  chi_link_activation_ack i_rn_rx_activation (
    .clk_i,
    .rst_ni,
    .linkactivereq_i    (hn_i.rx_linkactivereq),
    .linkactiveack_o    (rn_o.rx_linkactiveack),
    .credits_returned_i (rx_credits_returned),
    .state_o            (rn_rx_state)
  );

  assign rn_tx_state_o = rn_tx_state;
  assign rn_rx_state_o = rn_rx_state;

  ////////////////////////////////////////////////////////////////////////////////////////////////
  // Transmitted channels
  ////////////////////////////////////////////////////////////////////////////////////////////////

  logic [$clog2(chi_pkg::CHI_MAX_LCREDITS+1)-1:0] txreq_credits;
  logic [$clog2(chi_pkg::CHI_MAX_LCREDITS+1)-1:0] txrsp_credits;
  logic [$clog2(chi_pkg::CHI_MAX_LCREDITS+1)-1:0] txdat_credits;

  chi_link_tx_channel #(
    .FlitWidth ($bits(chi_pkg::chi_req_t))
  ) i_txreq (
    .clk_i,
    .rst_ni,
    .state_i    (rn_tx_state),
    .flit_i     (txreq_i),
    .valid_i    (txreq_valid_i),
    .ready_o    (txreq_ready_o),
    .flitpend_o (rn_o.txreq.flitpend),
    .flitv_o    (rn_o.txreq.flitv),
    .flit_o     (rn_o.txreq.flit),
    .lcrdv_i    (hn_i.txreq_lcrdv),
    .credits_o  (txreq_credits)
  );

  chi_link_tx_channel #(
    .FlitWidth ($bits(chi_pkg::chi_rsp_t))
  ) i_txrsp (
    .clk_i,
    .rst_ni,
    .state_i    (rn_tx_state),
    .flit_i     (txrsp_i),
    .valid_i    (txrsp_valid_i),
    .ready_o    (txrsp_ready_o),
    .flitpend_o (rn_o.txrsp.flitpend),
    .flitv_o    (rn_o.txrsp.flitv),
    .flit_o     (rn_o.txrsp.flit),
    .lcrdv_i    (hn_i.txrsp_lcrdv),
    .credits_o  (txrsp_credits)
  );

  chi_link_tx_channel #(
    .FlitWidth ($bits(chi_pkg::chi_dat_t))
  ) i_txdat (
    .clk_i,
    .rst_ni,
    .state_i    (rn_tx_state),
    .flit_i     (txdat_i),
    .valid_i    (txdat_valid_i),
    .ready_o    (txdat_ready_o),
    .flitpend_o (rn_o.txdat.flitpend),
    .flitv_o    (rn_o.txdat.flitv),
    .flit_o     (rn_o.txdat.flit),
    .lcrdv_i    (hn_i.txdat_lcrdv),
    .credits_o  (txdat_credits)
  );

  ////////////////////////////////////////////////////////////////////////////////////////////////
  // Received channels
  ////////////////////////////////////////////////////////////////////////////////////////////////



  chi_link_rx_channel #(
    .FlitWidth ($bits(chi_pkg::chi_rsp_t)),
    .Credits   (RspCredits)
  ) i_rxrsp (
    .clk_i,
    .rst_ni,
    .state_i          (rn_rx_state),
    .flitpend_i       (hn_i.rxrsp.flitpend),
    .flitv_i          (hn_i.rxrsp.flitv),
    .flit_i           (hn_i.rxrsp.flit),
    .is_lcrd_return_i (chi_pkg::chi_rsp_is_lcrd_return(hn_i.rxrsp.flit.opcode)),
    .lcrdv_o          (rn_o.rxrsp_lcrdv),
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
    .state_i          (rn_rx_state),
    .flitpend_i       (hn_i.rxdat.flitpend),
    .flitv_i          (hn_i.rxdat.flitv),
    .flit_i           (hn_i.rxdat.flit),
    .is_lcrd_return_i (chi_pkg::chi_dat_is_lcrd_return(hn_i.rxdat.flit.opcode)),
    .lcrdv_o          (rn_o.rxdat_lcrdv),
    .flit_o           (rxdat_o),
    .valid_o          (rxdat_valid_o),
    .ready_i          (rxdat_ready_i),
    .outstanding_o    (rxdat_outstanding)
  );

  chi_link_rx_channel #(
    .FlitWidth ($bits(chi_pkg::chi_snp_t)),
    .Credits   (SnpCredits)
  ) i_rxsnp (
    .clk_i,
    .rst_ni,
    .state_i          (rn_rx_state),
    .flitpend_i       (hn_i.rxsnp.flitpend),
    .flitv_i          (hn_i.rxsnp.flitv),
    .flit_i           (hn_i.rxsnp.flit),
    .is_lcrd_return_i (chi_pkg::chi_snp_is_lcrd_return(hn_i.rxsnp.flit.opcode)),
    .lcrdv_o          (rn_o.rxsnp_lcrdv),
    .flit_o           (rxsnp_o),
    .valid_o          (rxsnp_valid_o),
    .ready_i          (rxsnp_ready_i),
    .outstanding_o    (rxsnp_outstanding)
  );

  // Read only by the assertions inside the channels, and by nothing here.
  logic unused;
  assign unused = ^{txreq_credits, txrsp_credits, txdat_credits,
                    // RXSACTIVE and SYSCOACK are the home node's answers about
                    // power and system coherency. This end asks and does not
                    // act on either.
                    hn_i.rxsactive, hn_i.syscoack};

endmodule
