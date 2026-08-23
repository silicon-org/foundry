// The LINKACTIVE handshake for one direction of a CHI link.
//
// Each direction is brought up by the side that transmits on it: that side
// raises LINKACTIVEREQ and the receiving side answers with LINKACTIVEACK. Both
// sides then read the same two wires and agree on the state, which is why
// chi_pkg::chi_link_state() is in the package rather than in either of them.
//
// Two modules rather than one with a role parameter, because a role parameter
// leaves half the ports unused at every instantiation and the reader has to
// work out which half.

// The transmitting side: asks for the link, and takes the answer.
module chi_link_activation_req (
  input  logic clk_i,
  input  logic rst_ni,

  // Hold high to bring the link down again. The specification requires the
  // transmitter to return every unspent credit during DEACTIVATE before the
  // receiver may drop its acknowledgement, so this is a request rather than an
  // instruction and the state below is what says when it has taken effect.
  input  logic deactivate_i,

  output logic linkactivereq_o,
  input  logic linkactiveack_i,

  output chi_pkg::chi_link_state_e state_o
);

  // Registered, so that a link's pins are never a combinational function of the
  // other side's. Asserted the cycle after reset: a transmitter with nothing to
  // say still wants its link up, and waiting for traffic to ask for it only
  // moves the latency to the first transaction.
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) linkactivereq_o <= 1'b0;
    else linkactivereq_o <= !deactivate_i;
  end

  assign state_o = chi_pkg::chi_link_state(linkactivereq_o, linkactiveack_i);

endmodule
