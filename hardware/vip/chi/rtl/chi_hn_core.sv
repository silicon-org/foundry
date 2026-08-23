// A CHI home node: the SystemVerilog half joined to the C++ half.
//
// The mirror of chi_rn_core, and the same shape: valid/ready in, valid/ready
// out, flow control somebody else's. chi_hn_agent wraps it in a link for a
// point-to-point testbench; //hardware/ip/chi_noc attaches it to a crosspoint
// through a device port. Neither arrangement is visible from here.
//
// Extracted from chi_hn_agent rather than written twice. A DPI pump that exists
// in two places is a DPI pump that will be fixed in one of them.
`include "chi_hn_dpi.svh"

module chi_hn_core #(
    // The name the test registered its home node under.
    parameter string Name = "chi.hn"
) (
    input logic clk_i,
    input logic rst_ni,

    // From the fabric. Always taken; see chi_rn_core.
    input  chi_pkg::chi_req_t rx_req_i,
    input  logic              rx_req_valid_i,
    output logic              rx_req_ready_o,

    input  chi_pkg::chi_rsp_t rx_rsp_i,
    input  logic              rx_rsp_valid_i,
    output logic              rx_rsp_ready_o,

    input  chi_pkg::chi_dat_t rx_dat_i,
    input  logic              rx_dat_valid_i,
    output logic              rx_dat_ready_o,

    // Into the fabric.
    output chi_pkg::chi_rsp_t tx_rsp_o,
    output logic              tx_rsp_valid_o,
    input  logic              tx_rsp_ready_i,

    output chi_pkg::chi_dat_t tx_dat_o,
    output logic              tx_dat_valid_o,
    input  logic              tx_dat_ready_i,

    output chi_pkg::chi_snp_t tx_snp_o,
    output logic              tx_snp_valid_o,
    input  logic              tx_snp_ready_i
);

  assign rx_req_ready_o = 1'b1;
  assign rx_rsp_ready_o = 1'b1;
  assign rx_dat_ready_o = 1'b1;

  chandle hn;
  logic   bound;

  always_ff @(posedge clk_i) begin
    if (!bound) begin
      hn = chi_hn_bind(Name);
      bound <= 1'b1;
      assert (hn != null)
      else $fatal(1, "chi_hn_core: no home node was created as '%s'", Name);
    end
  end

  initial begin
    bound = 1'b0;

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

  chi_pkg::chi_rsp_t tx_rsp;
  chi_pkg::chi_dat_t tx_dat;
  chi_pkg::chi_snp_t tx_snp;
  logic              tx_rsp_valid;
  logic              tx_dat_valid;
  logic              tx_snp_valid;

  assign tx_rsp_o       = tx_rsp;
  assign tx_dat_o       = tx_dat;
  assign tx_snp_o       = tx_snp;
  assign tx_rsp_valid_o = tx_rsp_valid;
  assign tx_dat_valid_o = tx_dat_valid;
  assign tx_snp_valid_o = tx_snp_valid;

  // Arrivals first, then departures, so that a response the node produces from
  // a request that arrived this cycle can leave on the next one rather than the
  // one after. Both halves are in the same block for exactly that reason.
  always_ff @(posedge clk_i or negedge rst_ni) begin
    bit [$bits(chi_pkg::chi_rsp_t)-1:0] next_rsp;
    bit [$bits(chi_pkg::chi_dat_t)-1:0] next_dat;
    bit [$bits(chi_pkg::chi_snp_t)-1:0] next_snp;

    if (!rst_ni) begin
      tx_rsp       <= '0;
      tx_dat       <= '0;
      tx_snp       <= '0;
      tx_rsp_valid <= 1'b0;
      tx_dat_valid <= 1'b0;
      tx_snp_valid <= 1'b0;
    end else begin
      if (rx_req_valid_i) chi_hn_rx_req(hn, rx_req_i);
      if (rx_rsp_valid_i) chi_hn_rx_rsp(hn, rx_rsp_i);
      if (rx_dat_valid_i) chi_hn_rx_dat(hn, rx_dat_i);

      if (!tx_rsp_valid || tx_rsp_ready_i) begin
        tx_rsp_valid <= chi_hn_tx_rsp(hn, next_rsp);
        tx_rsp       <= chi_pkg::chi_rsp_t'(next_rsp);
      end
      if (!tx_dat_valid || tx_dat_ready_i) begin
        tx_dat_valid <= chi_hn_tx_dat(hn, next_dat);
        tx_dat       <= chi_pkg::chi_dat_t'(next_dat);
      end
      if (!tx_snp_valid || tx_snp_ready_i) begin
        tx_snp_valid <= chi_hn_tx_snp(hn, next_snp);
        tx_snp       <= chi_pkg::chi_snp_t'(next_snp);
      end
    end
  end

endmodule
