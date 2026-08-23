// What a crosspoint actually did, counted.
//
// Bound into `chi_xp_channel` rather than wired into it, so that the design
// carries no verification code and every instance is observed without anybody
// remembering to connect one. A bind's port list may name the target's internal
// signals directly, which is the whole reason to use one here: the interesting
// events -- which turn a flit took, who lost an arbitration -- are decisions the
// switch makes and never puts on a port.
//
// These bins are what decides the tests are enough. A suite that passes proves
// the cases in it work; the bins are what say the cases in it were the right
// ones. `chi_xp_channel_coverage_test` requires every reachable bin to be hit
// and every unreachable one to stay empty -- and the second half is the point,
// because a turn that is illegal and never taken and a turn that is illegal and
// quietly taken look identical in a report that only counts what happened.
//
// Three things are deliberately *not* counted here.
//
// **Per channel class.** `chi_xp_channel` cannot tell which of the four it is
// -- that is the whole point of the five numbers it takes -- so four sets of
// turn bins would be four copies of one piece of evidence. What does need
// covering per class is the *wiring* around it, and `chi_xp_test` and
// `chi_noc_mesh_all_classes_test` do that by sending on all four and checking
// none arrives on another's channel.
//
// **Every turn in every crosspoint of a mesh.** A bind reaches all sixty-four
// instances, but SystemVerilog has no way to index a hierarchical name, so
// aggregating them means writing out sixty-four paths. It would also be
// answering a question that is already answered better: whether every path
// through the mesh works is what `chi_noc_mesh_all_pairs_test` establishes
// directly, by delivering a flit down all 240 of them.
//
// And two more, because they are not the fabric's to have:
//
//   - L-Credit exhaustion, at zero and at maximum. That is a property of a CHI
//     link, and //hardware/vip/chi/test:chi_link_credit_test drives it against
//     the link layer directly. Counting it again here would test the same
//     module twice and imply the fabric had a say in it.
//   - Link activation and deactivation. The mesh ties its links to RUN and says
//     why (chi_xp_channel); the handshake is exercised by
//     //hardware/vip/chi/test:chi_link_deactivate_test. A bin that cannot be
//     hit by construction should not be in a list of bins that must be.
module chi_xp_channel_cov #(
    parameter int unsigned Ports = 6,
    parameter int unsigned PrioBits = 2,
    parameter logic [5:0] PortEnable = 6'h3f
) (
    input logic clk_i,
    input logic rst_ni,

    // The switch's own decisions, named as it names them.
    input logic [Ports-1:0][Ports-1:0]               head_valid,  // [input][output]
    input logic [Ports-1:0][Ports-1:0][PrioBits-1:0] head_prio,   // [input][output]
    input logic [Ports-1:0]                          pop,         // [input]
    input logic [Ports-1:0][$clog2(Ports)-1:0]       pop_port     // [input]
);

  localparam int unsigned Classes = 1 << PrioBits;

  // A flit left input `i` by output `o`. The illegal entries must stay zero.
  int unsigned turn[Ports][Ports];

  // Grants taken while `n` inputs were asking for that output. Index 1 is an
  // uncontended grant, 6 is every port at once.
  int unsigned contention[Ports+1];

  // A flit of priority class `w` won an output while a flit of class `l` was
  // also asking for it. The diagonal is a tie broken by round-robin; the upper
  // triangle is priority doing its job.
  int unsigned qos_win[Classes][Classes];

  // An input held a flit it could not place. Backpressure reached this far.
  int unsigned stalled[Ports];

  // How many inputs had something for output `o` this cycle. With one queue per
  // output the answer is a count of queue heads, not a search.
  function automatic int unsigned requesters_for(int unsigned o);
    int unsigned count = 0;
    for (int unsigned p = 0; p < Ports; p++) begin
      if (head_valid[p][o]) count++;
    end
    return count;
  endfunction

  // Blocking assignments throughout, and deliberately: several grants land in
  // one cycle, and `count <= count + 1` twice in a cycle increments once
  // because both read the same value. These are counters in a monitor, not
  // state in a design, so the usual rule buys nothing here.
  int unsigned n_requesters;
  int unsigned served;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      for (int unsigned a = 0; a < Ports; a++) begin
        stalled[a] = 0;
        for (int unsigned b = 0; b < Ports; b++) turn[a][b] = 0;
      end
      for (int unsigned n = 0; n <= Ports; n++) contention[n] = 0;
      for (int unsigned w = 0; w < Classes; w++) begin
        for (int unsigned l = 0; l < Classes; l++) qos_win[w][l] = 0;
      end
    end else begin
      for (int unsigned p = 0; p < Ports; p++) begin
        // Something to send and nothing sent. With per-output queues this is
        // the honest question -- a FIFO could only ever be blocked on its head.
        if (|head_valid[p] && !pop[p]) stalled[p] = stalled[p] + 1;

        if (pop[p]) begin
          served = {29'd0, pop_port[p]};
          turn[p][served] = turn[p][served] + 1;

          n_requesters = requesters_for(served);
          contention[n_requesters] = contention[n_requesters] + 1;

          // Everyone else with a flit for that output who did not get it. The
          // lower triangle of this table must stay empty: phase one masks to the
          // highest class present, so a lower class winning is priority not
          // working.
          for (int unsigned q = 0; q < Ports; q++) begin
            if (q != p && head_valid[q][served]) begin
              qos_win[head_prio[p][served]][head_prio[q][served]] =
                  qos_win[head_prio[p][served]][head_prio[q][served]] + 1;
            end
          end
        end
      end
    end
  end

  logic unused;
  assign unused = ^{PortEnable};

endmodule
