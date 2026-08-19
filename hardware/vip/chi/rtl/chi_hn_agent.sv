// A CHI home node on a link: the SystemVerilog half joined to the C++ half.
//
// chi_link_hn does the flow control and chi::HomeNode decides what the flits
// mean; this is the seam between them, and it is deliberately thin. Every clock
// edge it hands over whatever arrived and takes whatever is ready to go, one
// packed flit per call.
//
// The C++ node is built by the test's own main() and found here by name, so
// that a test can load its memory and set its watchpoints before the first
// clock edge. See //hardware/vip/chi/dpi/chi_hn_dpi.h.
`include "chi_hn_dpi.svh"

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

  chandle hn;

  // Bound on the first clock edge rather than in an initial block. The
  // testbench creates the node in an initial block of its own, and SystemVerilog
  // gives no ordering between two of those; by the first edge every one of them
  // has run.
  logic bound;

  always_ff @(posedge clk_i) begin
    if (!bound) begin
      hn = chi_hn_bind(Name);
      bound <= 1'b1;
      assert (hn != null)
      else $fatal(1, "chi_hn_agent: no home node was created as '%s'", Name);
    end
  end

  initial begin
    bound = 1'b0;

    // The DPI declarations carry literal widths because an import cannot be
    // parameterised. A package that disagreed would truncate every flit
    // silently, so the disagreement is caught here instead -- as an assertion,
    // because $error in a generate block is only a warning to Verilator.
    assert ($bits(chi_pkg::chi_req_t) == 162)
    else $fatal(1, "chi_hn_dpi.svh declares a 162-bit REQ flit; chi_pkg has %0d",
                $bits(chi_pkg::chi_req_t));
    assert ($bits(chi_pkg::chi_rsp_t) == 73)
    else $fatal(1, "chi_hn_dpi.svh declares a 73-bit RSP flit; chi_pkg has %0d",
                $bits(chi_pkg::chi_rsp_t));
    assert ($bits(chi_pkg::chi_dat_t) == 422)
    else $fatal(1, "chi_hn_dpi.svh declares a 422-bit DAT flit; chi_pkg has %0d",
                $bits(chi_pkg::chi_dat_t));
    assert ($bits(chi_pkg::chi_snp_t) == 115)
    else $fatal(1, "chi_hn_dpi.svh declares a 115-bit SNP flit; chi_pkg has %0d",
                $bits(chi_pkg::chi_snp_t));
  end

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

  ////////////////////////////////////////////////////////////////////////////////////////////////
  // The boundary
  //
  // Arrivals first, then departures, so that a response the node produces from
  // a request that arrived this cycle can leave on the next one rather than the
  // one after. Both halves are in the same block for exactly that reason.
  ////////////////////////////////////////////////////////////////////////////////////////////////

  always_ff @(posedge clk_i or negedge rst_ni) begin
    // Declared here rather than at module scope: they hold a flit between the
    // call that produces it and the assignment that registers it, and nothing
    // outside this block should be able to read them.
    bit [$bits(chi_pkg::chi_rsp_t)-1:0] next_rsp;
    bit [$bits(chi_pkg::chi_dat_t)-1:0] next_dat;
    bit [$bits(chi_pkg::chi_snp_t)-1:0] next_snp;

    if (!rst_ni) begin
      txrsp       <= '0;
      txdat       <= '0;
      txsnp       <= '0;
      txrsp_valid <= 1'b0;
      txdat_valid <= 1'b0;
      txsnp_valid <= 1'b0;
    end else begin
      if (rxreq_valid) chi_hn_rx_req(hn, rxreq);
      if (rxrsp_valid) chi_hn_rx_rsp(hn, rxrsp);
      if (rxdat_valid) chi_hn_rx_dat(hn, rxdat);

      // Ask only when the channel can take what comes back, because asking is
      // what removes it from the node's queue.
      if (!txrsp_valid || txrsp_ready) begin
        txrsp_valid <= chi_hn_tx_rsp(hn, next_rsp);
        txrsp       <= chi_pkg::chi_rsp_t'(next_rsp);
      end
      if (!txdat_valid || txdat_ready) begin
        txdat_valid <= chi_hn_tx_dat(hn, next_dat);
        txdat       <= chi_pkg::chi_dat_t'(next_dat);
      end
      if (!txsnp_valid || txsnp_ready) begin
        txsnp_valid <= chi_hn_tx_snp(hn, next_snp);
        txsnp       <= chi_pkg::chi_snp_t'(next_snp);
      end
    end
  end

endmodule
