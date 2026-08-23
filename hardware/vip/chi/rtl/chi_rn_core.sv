// A CHI request node: the SystemVerilog half joined to the C++ half.
//
// Flow control is somebody else's -- this speaks valid/ready and nothing more,
// so it attaches to a crosspoint through //hardware/ip/chi_noc's device port,
// or to a link through chi_link_rn, without knowing which. Every clock edge it
// hands over whatever arrived and takes whatever is ready to go, one packed
// flit per call.
//
// The C++ node is built by the test's own main() and found here by name, so a
// test can queue its work before the first clock edge. See
// //hardware/vip/chi/dpi/chi_rn_dpi.h.
`include "chi_rn_dpi.svh"

module chi_rn_core #(
    // The name the test registered its request node under.
    parameter string Name = "chi.rn"
) (
    input logic clk_i,
    input logic rst_ni,

    // From the fabric. Always taken: the C++ node queues internally and has no
    // reason to refuse a flit, and a receiver that could refuse would need a
    // second buffer here for no gain.
    input  chi_pkg::chi_rsp_t rx_rsp_i,
    input  logic              rx_rsp_valid_i,
    output logic              rx_rsp_ready_o,

    input  chi_pkg::chi_dat_t rx_dat_i,
    input  logic              rx_dat_valid_i,
    output logic              rx_dat_ready_o,

    input  chi_pkg::chi_snp_t rx_snp_i,
    input  logic              rx_snp_valid_i,
    output logic              rx_snp_ready_o,

    // Into the fabric.
    output chi_pkg::chi_req_t tx_req_o,
    output logic              tx_req_valid_o,
    input  logic              tx_req_ready_i,

    output chi_pkg::chi_rsp_t tx_rsp_o,
    output logic              tx_rsp_valid_o,
    input  logic              tx_rsp_ready_i,

    output chi_pkg::chi_dat_t tx_dat_o,
    output logic              tx_dat_valid_o,
    input  logic              tx_dat_ready_i
);

  assign rx_rsp_ready_o = 1'b1;
  assign rx_dat_ready_o = 1'b1;
  assign rx_snp_ready_o = 1'b1;

  chandle rn;
  logic   bound;

  // Bound on the first clock edge rather than in an initial block: the
  // testbench creates the node in an initial block of its own, and
  // SystemVerilog gives no ordering between two of those.
  always_ff @(posedge clk_i) begin
    if (!bound) begin
      rn = chi_rn_bind(Name);
      bound <= 1'b1;
      assert (rn != null)
      else $fatal(1, "chi_rn_core: no request node was created as '%s'", Name);
    end
  end

  initial begin
    bound = 1'b0;

    // The DPI declarations carry literal widths because an import cannot be
    // parameterised. A package that disagreed would truncate every flit
    // silently, so the disagreement is caught here instead -- as an assertion,
    // because $error in a generate block is only a warning to Verilator.
    assert ($bits(chi_pkg::chi_req_t) == 162)
    else $fatal(1, "chi_rn_dpi.svh declares a 162-bit REQ flit; chi_pkg has %0d",
                $bits(chi_pkg::chi_req_t));
    assert ($bits(chi_pkg::chi_rsp_t) == 73)
    else $fatal(1, "chi_rn_dpi.svh declares a 73-bit RSP flit; chi_pkg has %0d",
                $bits(chi_pkg::chi_rsp_t));
    assert ($bits(chi_pkg::chi_dat_t) == 422)
    else $fatal(1, "chi_rn_dpi.svh declares a 422-bit DAT flit; chi_pkg has %0d",
                $bits(chi_pkg::chi_dat_t));
    assert ($bits(chi_pkg::chi_snp_t) == 115)
    else $fatal(1, "chi_rn_dpi.svh declares a 115-bit SNP flit; chi_pkg has %0d",
                $bits(chi_pkg::chi_snp_t));
  end

  // Registered internally and published, so that the always_ff below assigns to
  // a variable rather than to a port and the intent is unambiguous.
  chi_pkg::chi_req_t tx_req;
  chi_pkg::chi_rsp_t tx_rsp;
  chi_pkg::chi_dat_t tx_dat;
  logic              tx_req_valid;
  logic              tx_rsp_valid;
  logic              tx_dat_valid;

  assign tx_req_o       = tx_req;
  assign tx_rsp_o       = tx_rsp;
  assign tx_dat_o       = tx_dat;
  assign tx_req_valid_o = tx_req_valid;
  assign tx_rsp_valid_o = tx_rsp_valid;
  assign tx_dat_valid_o = tx_dat_valid;

  // Arrivals first, then departures, so that a request the node produces from a
  // response that arrived this cycle can leave on the next one rather than the
  // one after. Both halves are in the same block for exactly that reason.
  always_ff @(posedge clk_i or negedge rst_ni) begin
    bit [$bits(chi_pkg::chi_req_t)-1:0] next_req;
    bit [$bits(chi_pkg::chi_rsp_t)-1:0] next_rsp;
    bit [$bits(chi_pkg::chi_dat_t)-1:0] next_dat;

    if (!rst_ni) begin
      tx_req       <= '0;
      tx_rsp       <= '0;
      tx_dat       <= '0;
      tx_req_valid <= 1'b0;
      tx_rsp_valid <= 1'b0;
      tx_dat_valid <= 1'b0;
    end else begin
      if (rx_rsp_valid_i) chi_rn_rx_rsp(rn, rx_rsp_i);
      if (rx_dat_valid_i) chi_rn_rx_dat(rn, rx_dat_i);
      if (rx_snp_valid_i) chi_rn_rx_snp(rn, rx_snp_i);

      // Ask only when the channel can take what comes back, because asking is
      // what removes it from the node's queue.
      if (!tx_req_valid || tx_req_ready_i) begin
        tx_req_valid <= chi_rn_tx_req(rn, next_req);
        tx_req       <= chi_pkg::chi_req_t'(next_req);
      end
      if (!tx_rsp_valid || tx_rsp_ready_i) begin
        tx_rsp_valid <= chi_rn_tx_rsp(rn, next_rsp);
        tx_rsp       <= chi_pkg::chi_rsp_t'(next_rsp);
      end
      if (!tx_dat_valid || tx_dat_ready_i) begin
        tx_dat_valid <= chi_rn_tx_dat(rn, next_dat);
        tx_dat       <= chi_pkg::chi_dat_t'(next_dat);
      end
    end
  end

endmodule
