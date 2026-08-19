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

// The receiving side: answers, and does not stop answering until every credit
// it handed out has come back.
module chi_link_activation_ack (
  input  logic clk_i,
  input  logic rst_ni,

  input  logic linkactivereq_i,
  output logic linkactiveack_o,

  // High when this side holds no credits outstanding. Dropping the
  // acknowledgement before that is what would lose a flit already in flight, so
  // it gates the fall of the acknowledgement and nothing else.
  input  logic credits_returned_i,

  output chi_pkg::chi_link_state_e state_o
);

  logic ack_d;
  assign ack_d = linkactivereq_i || !credits_returned_i;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) linkactiveack_o <= 1'b0;
    else linkactiveack_o <= ack_d;
  end

  assign state_o = chi_pkg::chi_link_state(linkactivereq_i, linkactiveack_o);

endmodule
