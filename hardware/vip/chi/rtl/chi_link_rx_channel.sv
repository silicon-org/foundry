// One CHI channel, receiving: L-Credits and a flit in, valid/ready out.
//
// The receiving end of a credit-based link cannot push back, so it must be able
// to absorb every flit it has granted a credit for. That makes the credit
// counter and the buffer one mechanism: a credit is granted when there is a
// place to put the flit it will bring, and not before. Depth and credit count
// are therefore the same number, and XiangShan's own receiver -- CoupledL2's
// LCredit2Decoupled -- is built the same way.
//
// Opcode zero is the L-Credit return on every channel. It is a flit for the
// purposes of flow control and not a message, so it is counted and dropped
// here; nothing downstream should have to know the difference. Which bits the
// opcode occupies is the caller's business -- it has the typed struct and this
// module does not -- so it arrives already decoded.
module chi_link_rx_channel #(
  parameter int unsigned FlitWidth = 1,

  // Credits granted, and so also the depth of the buffer behind them. The
  // specification caps this at 15.
  parameter int unsigned Credits = 4
) (
  input  logic clk_i,
  input  logic rst_ni,

  input  chi_pkg::chi_link_state_e state_i,

  // Inward, from the pins.
  input  logic                 flitpend_i,
  input  logic                 flitv_i,
  input  logic [FlitWidth-1:0] flit_i,
  // Whether the flit on flit_i is an L-Credit return, decoded by the caller from
  // the typed struct it has and this module does not.
  input  logic                 is_lcrd_return_i,
  output logic                 lcrdv_o,

  // Outward, valid/ready.
  output logic [FlitWidth-1:0] flit_o,
  output logic                 valid_o,
  input  logic                 ready_i,

  // Credits granted and not yet spent by the far end. The link may not finish
  // deactivating until every one has come back.
  output logic [$clog2(Credits+1)-1:0] outstanding_o
);

  // The level needs one more state than the depth -- empty through full -- while
  // a pointer needs only enough to index the buffer. Using one width for both
  // is a bit-extraction warning on every reference.
  localparam int unsigned CountWidth = $clog2(Credits + 1);
  localparam int unsigned PtrWidth = (Credits > 1) ? $clog2(Credits) : 1;

  // Unused, and named so. FLITPEND is an early indication for receivers that
  // clock-gate; there is nothing to gate here.
  logic unused_flitpend;
  assign unused_flitpend = flitpend_i;

  ////////////////////////////////////////////////////////////////////////////////////////////////
  // The buffer
  ////////////////////////////////////////////////////////////////////////////////////////////////

  logic [FlitWidth-1:0]  buffer_q[Credits];
  logic [CountWidth-1:0] level_q;
  logic [PtrWidth-1:0]   read_ptr_q;
  logic [PtrWidth-1:0]   write_ptr_q;

  // An L-Credit return is flow control, not a message: it consumes the credit
  // it was sent with and goes no further.
  logic push;
  logic pop;
  assign push = flitv_i && !is_lcrd_return_i;
  assign pop  = valid_o && ready_i;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      level_q     <= '0;
      read_ptr_q  <= '0;
      write_ptr_q <= '0;
    end else begin
      if (push) begin
        buffer_q[write_ptr_q] <= flit_i;
        write_ptr_q <= (write_ptr_q == PtrWidth'(Credits - 1)) ? '0 : write_ptr_q + 1'b1;
      end
      if (pop) read_ptr_q <= (read_ptr_q == PtrWidth'(Credits - 1)) ? '0 : read_ptr_q + 1'b1;
      if (push && !pop) level_q <= level_q + 1'b1;
      else if (pop && !push) level_q <= level_q - 1'b1;
    end
  end

  assign valid_o = level_q != '0;
  assign flit_o  = buffer_q[read_ptr_q];

  ////////////////////////////////////////////////////////////////////////////////////////////////
  // The credits
  //
  // One credit for every place in the buffer that is neither occupied nor
  // already promised to a flit in flight. `outstanding_q` is the promises.
  ////////////////////////////////////////////////////////////////////////////////////////////////

  logic [CountWidth-1:0] outstanding_q;

  logic grant;
  assign grant = (state_i == chi_pkg::CHI_LINK_RUN) &&
                 ((level_q + outstanding_q) < CountWidth'(Credits));

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) outstanding_q <= '0;
    else if (grant && !flitv_i) outstanding_q <= outstanding_q + 1'b1;
    else if (flitv_i && !grant) outstanding_q <= outstanding_q - 1'b1;
  end

  assign outstanding_o = outstanding_q;

  // Registered, as the transmitting side's flit and valid are, so that neither
  // end has a combinational path across the link.
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) lcrdv_o <= 1'b0;
    else lcrdv_o <= grant;
  end

  // A flit arrived that no credit was issued for. The transmitter is sending
  // beyond its allowance, or the two ends started counting at different times.
  always_ff @(posedge clk_i) begin
    if (rst_ni)
      assert (!(flitv_i && outstanding_q == '0))
      else $fatal(1, "chi_link_rx_channel: flit arrived with no L-Credit outstanding");
  end

  // The buffer is the promise behind every credit, so it cannot overflow unless
  // the accounting above is wrong.
  always_ff @(posedge clk_i) begin
    if (rst_ni)
      assert (!(push && level_q == CountWidth'(Credits)))
      else $fatal(1, "chi_link_rx_channel: flit arrived with the buffer full");
  end

endmodule
