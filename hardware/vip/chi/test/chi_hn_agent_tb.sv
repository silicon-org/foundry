// The whole CHI agent, with no design in the build.
//
// A request node's link on one side, a chi_hn_agent on the other, and between
// them everything a real testbench relies on: the credit layer, the DPI
// boundary, the C++ home node and the memory behind it. What it proves is the
// one thing the two tests either side of it cannot -- that a flit built in C++
// arrives in SystemVerilog with its bits where the package says they are, and
// that a request built in SystemVerilog reaches the C++ node meaning what it
// said.
//
// chi_link_loopback_tb covers the link with no protocol; chi_home_node_test
// covers the protocol with no link. This is the seam, and it is the piece that
// was missing when a real core fetched nine cache lines and then gave up.

`include "chi_hn_dpi.svh"
`include "vip_dpi.svh"

module chi_hn_agent_tb #(
  parameter time ClkHalfPeriod = 1ns,
  parameter int unsigned Timeout = 2000,

  parameter logic [47:0] Base = 48'h8000_0000,
  parameter int unsigned LineBytes = 64
);

  import chi_pkg::*;

  ////////////////////////////////////////////////////////////////////////////////////////////////
  // Clock, reset and the memory under the agent
  ////////////////////////////////////////////////////////////////////////////////////////////////

  logic clk;
  logic rst_n;

  initial begin
    clk = 1'b0;
    forever #ClkHalfPeriod clk = ~clk;
  end

  initial begin
    rst_n = 1'b0;
    repeat (4) @(negedge clk);
    rst_n = 1'b1;
  end

  string test_case;

  initial begin
    if (!$value$plusargs("case=%s", test_case))
      $fatal(1, "no +case= given; see BUILD.bazel for the cases this testbench has");
  end

  int unsigned cycle;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) cycle <= 0;
    else cycle <= cycle + 1;
  end

  initial begin
    wait (rst_n);
    repeat (Timeout) @(posedge clk);
    $fatal(1, "case %s: %0d cycles and it never finished", test_case, Timeout);
  end

  chandle memory;
  chandle home_node;

  // A word per address, distinct and derived from it, so that data delivered
  // from the wrong place is visible in its value rather than only in a count.
  function automatic int unsigned expected_word(logic [47:0] address);
    return 32'hC0DE_0000 + 32'(address[15:0]);
  endfunction

  initial begin
    memory = vip_mem_create();
    for (int unsigned i = 0; i < LineBytes / 4; i++)
      vip_mem_load_word(memory, 64'(Base) + 64'(i) * 4, expected_word(Base + 48'(i) * 4));
    home_node = chi_hn_create("chi.hn.agent_tb", 32'h2A, LineBytes, memory);
  end

  ////////////////////////////////////////////////////////////////////////////////////////////////
  // The link
  ////////////////////////////////////////////////////////////////////////////////////////////////

  chi_rn_link_tx_t rn_pins;
  chi_rn_link_rx_t hn_pins;

  chi_req_t rn_txreq;
  logic     rn_txreq_valid;
  logic     rn_txreq_ready;
  chi_rsp_t rn_txrsp;
  logic     rn_txrsp_valid;
  logic     rn_txrsp_ready;
  chi_dat_t rn_txdat;
  logic     rn_txdat_valid;
  logic     rn_txdat_ready;

  chi_rsp_t rn_rxrsp;
  logic     rn_rxrsp_valid;
  chi_dat_t rn_rxdat;
  logic     rn_rxdat_valid;
  chi_snp_t rn_rxsnp;
  logic     rn_rxsnp_valid;

  chi_link_state_e rn_tx_state;
  chi_link_state_e rn_rx_state;

  chi_link_rn i_rn (
    .clk_i         (clk),
    .rst_ni        (rst_n),
    .deactivate_i  (1'b0),
    .rn_o          (rn_pins),
    .hn_i          (hn_pins),
    .txreq_i       (rn_txreq),
    .txreq_valid_i (rn_txreq_valid),
    .txreq_ready_o (rn_txreq_ready),
    .txrsp_i       (rn_txrsp),
    .txrsp_valid_i (rn_txrsp_valid),
    .txrsp_ready_o (rn_txrsp_ready),
    .txdat_i       (rn_txdat),
    .txdat_valid_i (rn_txdat_valid),
    .txdat_ready_o (rn_txdat_ready),
    .rxrsp_o       (rn_rxrsp),
    .rxrsp_valid_o (rn_rxrsp_valid),
    .rxrsp_ready_i (1'b1),
    .rxdat_o       (rn_rxdat),
    .rxdat_valid_o (rn_rxdat_valid),
    .rxdat_ready_i (1'b1),
    .rxsnp_o       (rn_rxsnp),
    .rxsnp_valid_o (rn_rxsnp_valid),
    .rxsnp_ready_i (1'b1),
    .rn_tx_state_o (rn_tx_state),
    .rn_rx_state_o (rn_rx_state)
  );

  chi_hn_agent #(
    .Name ("chi.hn.agent_tb")
  ) i_hn (
    .clk_i         (clk),
    .rst_ni        (rst_n),
    .rn_i          (rn_pins),
    .hn_o          (hn_pins),
    .rn_tx_state_o (),
    .rn_rx_state_o ()
  );

  ////////////////////////////////////////////////////////////////////////////////////////////////
  // What came back
  ////////////////////////////////////////////////////////////////////////////////////////////////

  int unsigned dat_seen;
  int unsigned rsp_seen;
  chi_dat_t    dat_log[8];
  chi_rsp_t    last_rsp;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      dat_seen <= 0;
      rsp_seen <= 0;
    end else begin
      if (rn_rxdat_valid) begin
        if (dat_seen < 8) dat_log[dat_seen] <= rn_rxdat;
        dat_seen <= dat_seen + 1;
      end
      if (rn_rxrsp_valid) begin
        last_rsp <= rn_rxrsp;
        rsp_seen <= rsp_seen + 1;
      end
    end
  end

  ////////////////////////////////////////////////////////////////////////////////////////////////
  // Drivers, on the falling edge and observed through a registered flag; see
  // chi_link_loopback_tb.sv for why.
  ////////////////////////////////////////////////////////////////////////////////////////////////

  logic rn_txreq_fired;
  logic rn_txrsp_fired;
  logic rn_txdat_fired;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rn_txreq_fired <= 1'b0;
      rn_txrsp_fired <= 1'b0;
      rn_txdat_fired <= 1'b0;
    end else begin
      rn_txreq_fired <= rn_txreq_valid && rn_txreq_ready;
      rn_txrsp_fired <= rn_txrsp_valid && rn_txrsp_ready;
      rn_txdat_fired <= rn_txdat_valid && rn_txdat_ready;
    end
  end

  task automatic await_running();
    while (rn_tx_state != CHI_LINK_RUN || rn_rx_state != CHI_LINK_RUN) @(posedge clk);
  endtask

  task automatic send_req(chi_req_opcode_e opcode, logic [47:0] address, logic [2:0] size,
                          logic [11:0] txn_id, logic exp_comp_ack);
    chi_req_t f = '0;
    f.src_id       = 11'h15;
    f.tgt_id       = 11'h2A;
    f.txn_id       = txn_id;
    f.opcode       = opcode;
    f.addr         = address;
    f.size         = size;
    f.exp_comp_ack = exp_comp_ack;

    @(negedge clk);
    rn_txreq       = f;
    rn_txreq_valid = 1'b1;
    do @(negedge clk); while (!rn_txreq_fired);
    rn_txreq_valid = 1'b0;
  endtask

  task automatic send_write_data(logic [11:0] dbid, logic [1:0] data_id, logic [255:0] data,
                                 logic [31:0] byte_enables);
    chi_dat_t f = '0;
    f.src_id  = 11'h15;
    f.tgt_id  = 11'h2A;
    f.txn_id  = dbid;
    f.opcode  = CHI_DAT_NON_COPY_BACK_WR_DATA;
    f.data_id = data_id;
    f.be      = byte_enables;
    f.data    = data;

    @(negedge clk);
    rn_txdat       = f;
    rn_txdat_valid = 1'b1;
    do @(negedge clk); while (!rn_txdat_fired);
    rn_txdat_valid = 1'b0;
  endtask

  ////////////////////////////////////////////////////////////////////////////////////////////////
  // The cases
  ////////////////////////////////////////////////////////////////////////////////////////////////

  // A full cache line, and every word of it compared against what was loaded.
  // Byte order inside a flit, the DataID that says which half a beat is, and the
  // DPI packing all have to be right for this to pass, and none of them is
  // checked anywhere else.
  task automatic case_read_line();
    await_running();
    send_req(CHI_REQ_READ_NO_SNP, Base, 3'd6, 12'h1, 1'b0);

    while (dat_seen < 2) @(posedge clk);
    repeat (2) @(posedge clk);

    assert (dat_seen == 2)
    else $error("%0d data beats for a 64-byte read, expected 2", dat_seen);
    assert (dat_log[0].opcode == CHI_DAT_COMP_DATA)
    else $error("first beat is opcode %s", dat_log[0].opcode.name());
    assert (dat_log[0].data_id == 2'd0 && dat_log[1].data_id == 2'd2)
    else $error("DataIDs are %0d and %0d, expected 0 and 2", dat_log[0].data_id,
                dat_log[1].data_id);
    assert (dat_log[0].txn_id == 12'h1)
    else $error("beat carries TxnID %0h, expected 1", dat_log[0].txn_id);

    for (int unsigned word = 0; word < 8; word++) begin
      assert (dat_log[0].data[word*32 +: 32] == expected_word(Base + 48'(word) * 4))
      else
        $error("first beat word %0d is %08h, expected %08h", word,
               dat_log[0].data[word*32 +: 32], expected_word(Base + 48'(word) * 4));
      assert (dat_log[1].data[word*32 +: 32] == expected_word(Base + 48'd32 + 48'(word) * 4))
      else
        $error("second beat word %0d is %08h, expected %08h", word,
               dat_log[1].data[word*32 +: 32], expected_word(Base + 48'd32 + 48'(word) * 4));
    end

    $display("read_line: 64 bytes over two beats, every word as loaded");
  endtask

  // A store, all the way to memory and back out through a DPI read. This is the
  // path a program's `sw` takes.
  task automatic case_write_word();
    logic [255:0] payload;
    await_running();

    send_req(CHI_REQ_WRITE_NO_SNP_PTL, Base + 48'h40, 3'd2, 12'h2, 1'b0);
    while (rsp_seen < 1) @(posedge clk);

    assert (last_rsp.opcode == CHI_RSP_COMP_DBID_RESP)
    else $error("answer to a write is %s, expected CompDBIDResp", last_rsp.opcode.name());

    payload = '0;
    payload[31:0] = 32'hFEED_FACE;
    // The low four bytes only, which is what a word store looks like on the wire.
    send_write_data(last_rsp.db_id, 2'd0, payload, 32'h0000_000F);

    repeat (4) @(posedge clk);
    assert (vip_mem_read_word(memory, 64'(Base) + 64'h40) == 32'hFEED_FACE)
    else
      $error("memory holds %08h after the write, expected feedface",
             vip_mem_read_word(memory, 64'(Base) + 64'h40));

    $display("write_word: a word store reached memory through the agent");
  endtask

  initial begin
    rn_txreq       = '0;
    rn_txreq_valid = 1'b0;
    rn_txrsp       = '0;
    rn_txrsp_valid = 1'b0;
    rn_txdat       = '0;
    rn_txdat_valid = 1'b0;

    wait (rst_n);
    @(posedge clk);

    case (test_case)
      "read_line":  case_read_line();
      "write_word": case_write_word();
      default: $fatal(1, "unknown case '%s'", test_case);
    endcase

    repeat (4) @(posedge clk);
    vip_test_pass($sformatf("case %s ran to its end", test_case));
    $finish;
  end

endmodule
