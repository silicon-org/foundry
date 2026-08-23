// One crosspoint input: credits, a payload memory, and a queue per output.
//
// The structure is the point, so it is worth stating plainly. A flit arriving
// here is split in two:
//
//   - its **payload** -- all 422 bits of a DAT flit -- goes into a memory with
//     one write port and one read port, whose output is registered. That is
//     what an SRAM is, and it is written that way now so the pipeline never has
//     to change when it becomes one. Nothing searches it; it is only ever read
//     at an index somebody else worked out.
//   - its **routing information** -- which output, and how urgently -- is used
//     once, to choose a queue, and then lives in a flop array a fraction of the
//     size, which is linked and re-linked every cycle.
//
// That split is what makes looking past a blocked flit affordable. The obvious
// way to do it -- let the arbiter consider every buffered entry -- costs
// `Credits * Ports` candidates per output, thirty-six at the current depth, and
// an O(Credits^2) check that no older entry in the same buffer is going to the
// same place. Linking the entries into **one queue per output** instead means
// each output arbitrates over six queue heads, exactly as many as before, and
// per-(input, output) order is kept by the queue rather than by a comparison.
// The concurrent pick stops being a search and becomes a dereference.
//
// Two things follow that are easy to miss:
//
//   - The destination is **not** stored per entry. Which output an entry wants
//     is which list it is on, so keeping the field as well would be keeping the
//     same fact twice and inviting them to disagree.
//   - Flits to *different* outputs may leave in a different order than they
//     arrived. That is permitted: CHI orders a channel between one source and
//     one destination, and deterministic routing puts every flit of such a pair
//     on the same queue here.
module chi_xp_input_buffer
  import chi_noc_pkg::CHI_XP_PORTS;
#(
    parameter int unsigned FlitWidth = 1,
    parameter int unsigned PrioBits  = 2,

    // Entries, and so also the L-Credits granted: a credit is the promise of
    // somewhere to put the flit it will bring. Six, because the credit round
    // trip is five cycles; see chi_xp_channel.
    parameter int unsigned Credits = 10
) (
    input logic clk_i,
    input logic rst_ni,

    input chi_pkg::chi_link_state_e state_i,

    ////////////////////////////////////////////////////////////////////////////////////////////////
    // From the link
    ////////////////////////////////////////////////////////////////////////////////////////////////

    input  logic                 flitv_i,
    input  logic [FlitWidth-1:0] flit_i,
    input  logic                 is_lcrd_return_i,
    output logic                 lcrdv_o,

    // Where the arriving flit is going and how urgently, worked out by the
    // caller, which has the route function and knows where the fields sit.
    // Computed once on arrival rather than every cycle from a flit inside what
    // wants to be an SRAM.
    input  logic [CHI_XP_PORTS-1:0] dest_i,
    input  logic [PrioBits-1:0]     prio_i,

    ////////////////////////////////////////////////////////////////////////////////////////////////
    // To the crossbar
    //
    // One head per output rather than one head in total. This is the whole
    // difference from a FIFO, and everything the scheduler reads: six valid
    // bits and six priorities, eighteen bits in all.
    ////////////////////////////////////////////////////////////////////////////////////////////////

    output logic [CHI_XP_PORTS-1:0]               head_valid_o,
    output logic [CHI_XP_PORTS-1:0][PrioBits-1:0] head_prio_o,

    // Take the head of one output's queue. At most one per cycle: the payload
    // memory has one read port and the link out of here carries one flit.
    //
    // The flit appears **the cycle after** `pop_i`, because the memory's output
    // is registered. A caller that pops has undertaken to have somewhere for it
    // to land next cycle -- see the reservation in chi_xp_channel.
    input  logic                            pop_i,
    input  logic [$clog2(CHI_XP_PORTS)-1:0] pop_port_i,
    output logic [FlitWidth-1:0]            pop_flit_o
);

  localparam int unsigned Ports = CHI_XP_PORTS;
  localparam int unsigned IdxWidth = (Credits > 1) ? $clog2(Credits) : 1;
  localparam int unsigned CountWidth = $clog2(Credits + 1);
  localparam int unsigned PortIdxWidth = $clog2(Ports);

  typedef logic [IdxWidth-1:0] index_t;

  ////////////////////////////////////////////////////////////////////////////////////////////////
  // The payload memory: one write, one read, registered output
  ////////////////////////////////////////////////////////////////////////////////////////////////

  logic [FlitWidth-1:0] payload_q[Credits];
  logic [FlitWidth-1:0] read_data_q;

  assign pop_flit_o = read_data_q;

  ////////////////////////////////////////////////////////////////////////////////////////////////
  // The lists
  //
  // `next_q` threads two kinds of list through the same entries: the free list,
  // and one queue per output. An entry is on exactly one of them at any moment.
  ////////////////////////////////////////////////////////////////////////////////////////////////

  logic [PrioBits-1:0] prio_q[Credits];
  index_t              next_q[Credits];

  index_t free_head_q;

  index_t              queue_head_q[Ports];
  index_t              queue_tail_q[Ports];
  logic                queue_valid_q[Ports];
  // The head's priority, kept beside the queue rather than read out of the
  // array. Twelve bits that keep an indexed read off the arbitration path.
  logic [PrioBits-1:0] queue_prio_q[Ports];

  logic [CountWidth-1:0] level_q;

  ////////////////////////////////////////////////////////////////////////////////////////////////
  // Credits
  //
  // Unchanged from chi_link_rx_channel, because the accounting belongs to the
  // link and not to how the flits are stored: a credit is granted when there is
  // a place for the flit it will bring, counting places already promised to
  // flits in flight.
  ////////////////////////////////////////////////////////////////////////////////////////////////

  logic [CountWidth-1:0] outstanding_q;

  logic push;
  assign push = flitv_i && !is_lcrd_return_i;

  logic grant;
  assign grant = (state_i == chi_pkg::CHI_LINK_RUN) &&
                 ((level_q + outstanding_q) < CountWidth'(Credits));

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) outstanding_q <= '0;
    else if (grant && !flitv_i) outstanding_q <= outstanding_q + 1'b1;
    else if (flitv_i && !grant) outstanding_q <= outstanding_q - 1'b1;
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) lcrdv_o <= 1'b0;
    else lcrdv_o <= grant;
  end

  ////////////////////////////////////////////////////////////////////////////////////////////////
  // Bookkeeping
  ////////////////////////////////////////////////////////////////////////////////////////////////

  // Which queue an arriving flit joins. `dest_i` is one-hot by construction --
  // chi_xp_route returns one bit -- and the assertion in chi_xp_channel is what
  // says so.
  logic [PortIdxWidth-1:0] push_port;

  always_comb begin
    push_port = '0;
    for (int unsigned o = 0; o < Ports; o++) begin
      if (dest_i[o]) push_port = PortIdxWidth'(o);
    end
  end

  index_t popped;
  assign popped = queue_head_q[pop_port_i];

  // The freed entry is where the arriving flit goes when both happen at once.
  // A push can never find the free list empty: a credit was granted only
  // because a place was reserved, so `level_q < Credits` whenever `push`.
  index_t allocated;
  assign allocated = free_head_q;

  // A pop that empties a queue, so a push to the same queue this cycle makes
  // the new entry the head rather than appending to a tail that means nothing.
  logic pop_empties;
  assign pop_empties = pop_i && (queue_head_q[pop_port_i] == queue_tail_q[pop_port_i]);

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      level_q     <= '0;
      free_head_q <= '0;
      read_data_q <= '0;
      for (int unsigned e = 0; e < Credits; e++) begin
        // The free list, chained in order. The last entry's pointer is never
        // followed, because a push only happens when the list is non-empty.
        next_q[e] <= IdxWidth'((e + 1) % Credits);
        prio_q[e] <= '0;
      end
      for (int unsigned o = 0; o < Ports; o++) begin
        queue_head_q[o]  <= '0;
        queue_tail_q[o]  <= '0;
        queue_valid_q[o] <= 1'b0;
        queue_prio_q[o]  <= '0;
      end
    end else begin
      // -- the read, one cycle ahead of its data ------------------------------
      if (pop_i) read_data_q <= payload_q[popped];

      // -- off the front of a queue ------------------------------------------
      if (pop_i) begin
        if (pop_empties) begin
          queue_valid_q[pop_port_i] <= 1'b0;
        end else begin
          queue_head_q[pop_port_i] <= next_q[popped];
          queue_prio_q[pop_port_i] <= prio_q[next_q[popped]];
        end
      end

      // -- onto the free list, and off it ------------------------------------
      //
      // Both can happen in one cycle. The pushed flit takes the old free head;
      // the popped entry becomes the new one, pointing at what the old head
      // pointed at.
      if (pop_i && push) begin
        next_q[popped] <= next_q[allocated];
        free_head_q    <= popped;
      end else if (pop_i) begin
        next_q[popped] <= free_head_q;
        free_head_q    <= popped;
      end else if (push) begin
        free_head_q <= next_q[allocated];
      end

      // -- onto the back of a queue ------------------------------------------
      if (push) begin
        payload_q[allocated] <= flit_i;
        prio_q[allocated]    <= prio_i;

        if (!queue_valid_q[push_port] || (pop_empties && (push_port == pop_port_i))) begin
          queue_head_q[push_port]  <= allocated;
          queue_prio_q[push_port]  <= prio_i;
          queue_valid_q[push_port] <= 1'b1;
        end else begin
          next_q[queue_tail_q[push_port]] <= allocated;
        end
        queue_tail_q[push_port] <= allocated;
      end

      if (push && !pop_i) level_q <= level_q + 1'b1;
      else if (pop_i && !push) level_q <= level_q - 1'b1;
    end
  end

  for (genvar o = 0; o < Ports; o++) begin : gen_head
    assign head_valid_o[o] = queue_valid_q[o];
    assign head_prio_o[o]  = queue_prio_q[o];
  end

  ////////////////////////////////////////////////////////////////////////////////////////////////
  // What must never happen
  ////////////////////////////////////////////////////////////////////////////////////////////////

  always_ff @(posedge clk_i) begin
    if (rst_ni) begin
      // A flit arrived that no credit was issued for. The transmitter is
      // sending beyond its allowance, or the two ends started counting at
      // different times.
      assert (!(flitv_i && outstanding_q == '0))
      else $fatal(1, "chi_xp_input_buffer: flit arrived with no L-Credit outstanding");

      // The buffer is the promise behind every credit, so it cannot overflow
      // unless the accounting above is wrong.
      assert (!(push && !pop_i && level_q == CountWidth'(Credits)))
      else $fatal(1, "chi_xp_input_buffer: flit arrived with the buffer full");

      // Popping a queue with nothing on it means the crossbar granted an output
      // this input never offered.
      assert (!(pop_i && !queue_valid_q[pop_port_i]))
      else $fatal(1, "chi_xp_input_buffer: popped output %0d, whose queue is empty", pop_port_i);
    end
  end

endmodule
