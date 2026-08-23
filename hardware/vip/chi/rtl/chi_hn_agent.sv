// A CHI home node on a link: the SystemVerilog half joined to the C++ half.
//
// chi_link_hn does the flow control and chi::HomeNode decides what the flits
// mean; this is the seam between them, and it is deliberately thin. Every clock
// edge it hands over whatever arrived and takes whatever is ready to go, one
// packed flit per call.
//
// The pump itself is chi_hn_core, which //hardware/ip/chi_noc also uses to hang
// a home node off a crosspoint. What this module adds is the link: the two are
// separate because flow control and the DPI boundary change for different
// reasons.

module chi_hn_agent #(
  // The name the test registered its home node under.
  parameter string Name = "chi.hn",

  // Credits granted on each inbound channel. See chi_link_hn.
  parameter int unsigned ReqCredits = 4,
  parameter int unsigned RspCredits = 4,
  parameter int unsigned DatCredits = 4
) (
  input  logic clk_i,
  input  logic rst_ni,

  input  chi_pkg::chi_rn_link_tx_t rn_i,
  output chi_pkg::chi_rn_link_rx_t hn_o,

  output chi_pkg::chi_link_state_e rn_tx_state_o,
  output chi_pkg::chi_link_state_e rn_rx_state_o
);

  ////////////////////////////////////////////////////////////////////////////////////////////////
  // The link
  ////////////////////////////////////////////////////////////////////////////////////////////////

  chi_pkg::chi_req_t rxreq;
  chi_pkg::chi_rsp_t rxrsp;
  chi_pkg::chi_dat_t rxdat;
  logic              rxreq_valid;
  logic              rxrsp_valid;
  logic              rxdat_valid;

  chi_pkg::chi_rsp_t txrsp;
  chi_pkg::chi_dat_t txdat;
  chi_pkg::chi_snp_t txsnp;
  logic              txrsp_valid;
  logic              txdat_valid;
  logic              txsnp_valid;
  logic              txrsp_ready;
  logic              txdat_ready;
  logic              txsnp_ready;

  chi_link_hn #(
    .ReqCredits (ReqCredits),
    .RspCredits (RspCredits),
    .DatCredits (DatCredits)
  ) i_link (
    .clk_i,
    .rst_ni,
    .deactivate_i  (1'b0),
    .rn_i,
    .hn_o,
    .rxreq_o       (rxreq),
    .rxreq_valid_o (rxreq_valid),
    // Always taken. The C++ node queues internally and has no reason to refuse
    // a flit, and a receiver that could refuse would need a second buffer here
    // for no gain.
    .rxreq_ready_i (1'b1),
    .rxrsp_o       (rxrsp),
    .rxrsp_valid_o (rxrsp_valid),
    .rxrsp_ready_i (1'b1),
    .rxdat_o       (rxdat),
    .rxdat_valid_o (rxdat_valid),
    .rxdat_ready_i (1'b1),
    .txrsp_i       (txrsp),
    .txrsp_valid_i (txrsp_valid),
    .txrsp_ready_o (txrsp_ready),
    .txdat_i       (txdat),
    .txdat_valid_i (txdat_valid),
    .txdat_ready_o (txdat_ready),
    .txsnp_i       (txsnp),
    .txsnp_valid_i (txsnp_valid),
    .txsnp_ready_o (txsnp_ready),
    .rn_tx_state_o,
    .rn_rx_state_o
  );

  chi_hn_core #(
      .Name(Name)
  ) i_core (
      .clk_i,
      .rst_ni,
      .rx_req_i      (rxreq),
      .rx_req_valid_i(rxreq_valid),
      .rx_req_ready_o(),
      .rx_rsp_i      (rxrsp),
      .rx_rsp_valid_i(rxrsp_valid),
      .rx_rsp_ready_o(),
      .rx_dat_i      (rxdat),
      .rx_dat_valid_i(rxdat_valid),
      .rx_dat_ready_o(),
      .tx_rsp_o      (txrsp),
      .tx_rsp_valid_o(txrsp_valid),
      .tx_rsp_ready_i(txrsp_ready),
      .tx_dat_o      (txdat),
      .tx_dat_valid_o(txdat_valid),
      .tx_dat_ready_i(txdat_ready),
      .tx_snp_o      (txsnp),
      .tx_snp_valid_o(txsnp_valid),
      .tx_snp_ready_i(txsnp_ready)
  );

endmodule
