// Real CHI transactions across the reference mesh.
//
// Everything before this tested the fabric as a thing that moves flits: the
// right flit, to the right port, in the right order, fast enough. This is the
// first testbench that asks whether it moves *transactions* -- whether a read
// issued at one corner comes back with the bytes a write from another corner
// put there, having crossed six crosspoints and four channel classes to do it.
//
// Eight request nodes and four home nodes, all of them the C++ models from
// //hardware/vip/chi, attached to the mesh through //hardware/ip/chi_noc's
// device port. The models were already checked against each other with no
// simulator at all (chi_request_node_test), which is what makes this test
// about the fabric: if the two ends agree about CHI in isolation, a
// disagreement here is something in between them.
//
// The address map is the generated one. A line's home node is
// `RegionTarget[region][line % ways]`, so consecutive lines from one requester
// land on different home nodes -- which is the point of interleaving, and
// incidentally means every requester talks to every home node.
`include "chi_rn_dpi.svh"
`include "chi_hn_dpi.svh"
`include "vip_dpi.svh"

module chi_noc_system_tb #(
    parameter time ClkHalfPeriod = 1ns,

    // Lines each requester writes and then reads back. Eight requesters, two
    // transactions per line, two beats each: enough to fill the mesh several
    // times over without making the run long.
    parameter int unsigned LinesPerRequester = 16,

    parameter int unsigned Timeout = 200000
);

  import chi_noc_flit_pkg::chi_xp_port_t;
  import mesh4x4_noc_pkg::*;

  localparam int unsigned Devices = NumDevices;
  localparam int unsigned Requesters = 8;
  localparam int unsigned Homes = 4;

  // Which device index each agent hangs off. From the generated package, so
  // moving a node in the topology moves it here.
  localparam int unsigned RequesterIndex[Requesters] = '{
      RNF0_INDEX, RNF1_INDEX, RNF2_INDEX, RNF3_INDEX,
      RNF4_INDEX, RNF5_INDEX, RNF6_INDEX, RNF7_INDEX
  };
  localparam int unsigned HomeIndex[Homes] = '{HNF0_INDEX, HNF1_INDEX, HNF2_INDEX, HNF3_INDEX};

  // The names the C++ models are registered under. A string built with
  // $sformatf is not a constant expression, so the names are written out.
  localparam string RequesterName[Requesters] = '{
      "rnf0", "rnf1", "rnf2", "rnf3", "rnf4", "rnf5", "rnf6", "rnf7"
  };
  localparam string HomeName[Homes] = '{"hnf0", "hnf1", "hnf2", "hnf3"};

  ////////////////////////////////////////////////////////////////////////////////////////////////
  // Clock and reset
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

  ////////////////////////////////////////////////////////////////////////////////////////////////
  // The models, and the work they are given
  //
  // One memory behind all four home nodes. They front the same DRAM and the
  // address map sends each line to exactly one of them, so sharing the store is
  // what the system actually looks like -- and it means a requester's writes can
  // be checked against one place rather than reassembled from four.
  ////////////////////////////////////////////////////////////////////////////////////////////////

  chandle memory;
  chandle home[Homes];
  chandle requester[Requesters];

  // The address map, in the testbench, because there is no chi_sam.sv yet: a
  // line's home is RegionTarget[0][line % ways]. This is the RN-side SAM, and
  // when it becomes RTL this function is what it has to agree with.
  function automatic int unsigned home_for(logic [AddrWidth-1:0] address);
    logic [AddrWidth-1:0] offset = address - RegionBase[0];
    return int'(RegionTarget[0][(offset / LineBytes) % RegionWays[0]]);
  endfunction

  // Disjoint per requester, so no two of them ever touch the same line. This
  // fabric is transport and the home node models no directory, so coherence
  // between requesters is nobody's job here; partitioning is how that is made
  // true rather than assumed.
  function automatic logic [AddrWidth-1:0] address_of(int unsigned who, int unsigned line);
    return RegionBase[0] + AddrWidth'((who * LinesPerRequester + line) * LineBytes);
  endfunction

  initial begin
    memory = vip_mem_create();

    for (int unsigned h = 0; h < Homes; h++) begin
      home[h] = chi_hn_create(HomeName[h], DeviceNodeId[HomeIndex[h]], LineBytes, memory);
    end

    for (int unsigned r = 0; r < Requesters; r++) begin
      requester[r] = chi_rn_create(RequesterName[r], DeviceNodeId[RequesterIndex[r]], LineBytes,
                                   32'd8);
    end
  end

  ////////////////////////////////////////////////////////////////////////////////////////////////
  // The mesh, and what hangs off it
  ////////////////////////////////////////////////////////////////////////////////////////////////

  chi_xp_port_t [Devices-1:0] dev_rx;
  chi_xp_port_t [Devices-1:0] dev_tx;

  mesh4x4_noc i_mesh (
      .clk_i   (clk),
      .rst_ni  (rst_n),
      .dev_rx_i(dev_rx),
      .dev_tx_o(dev_tx)
  );

  // Every device gets a port, including the four with nothing on them. A port
  // with its device side tied off still grants credits, so a flit misrouted to
  // it would be delivered and counted rather than jamming an input for ever --
  // which is a better failure than a starvation assertion in the middle of a
  // mesh.
  chi_pkg::chi_req_t d_rx_req[Devices];
  chi_pkg::chi_rsp_t d_rx_rsp[Devices];
  chi_pkg::chi_dat_t d_rx_dat[Devices];
  chi_pkg::chi_snp_t d_rx_snp[Devices];
  logic d_rx_req_valid[Devices], d_rx_rsp_valid[Devices];
  logic d_rx_dat_valid[Devices], d_rx_snp_valid[Devices];
  logic d_rx_req_ready[Devices], d_rx_rsp_ready[Devices];
  logic d_rx_dat_ready[Devices], d_rx_snp_ready[Devices];

  chi_pkg::chi_req_t d_tx_req[Devices];
  chi_pkg::chi_rsp_t d_tx_rsp[Devices];
  chi_pkg::chi_dat_t d_tx_dat[Devices];
  chi_pkg::chi_snp_t d_tx_snp[Devices];
  logic d_tx_req_valid[Devices], d_tx_rsp_valid[Devices];
  logic d_tx_dat_valid[Devices], d_tx_snp_valid[Devices];
  logic d_tx_req_ready[Devices], d_tx_rsp_ready[Devices];
  logic d_tx_dat_ready[Devices], d_tx_snp_ready[Devices];

  for (genvar d = 0; d < Devices; d++) begin : gen_port
    chi_noc_device_port i_port (
        .clk_i (clk),
        .rst_ni(rst_n),
        .xp_i  (dev_tx[d]),
        .xp_o  (dev_rx[d]),

        .rx_req_o      (d_rx_req[d]),
        .rx_req_valid_o(d_rx_req_valid[d]),
        .rx_req_ready_i(d_rx_req_ready[d]),
        .rx_rsp_o      (d_rx_rsp[d]),
        .rx_rsp_valid_o(d_rx_rsp_valid[d]),
        .rx_rsp_ready_i(d_rx_rsp_ready[d]),
        .rx_dat_o      (d_rx_dat[d]),
        .rx_dat_valid_o(d_rx_dat_valid[d]),
        .rx_dat_ready_i(d_rx_dat_ready[d]),
        .rx_snp_o      (d_rx_snp[d]),
        .rx_snp_valid_o(d_rx_snp_valid[d]),
        .rx_snp_ready_i(d_rx_snp_ready[d]),

        .tx_req_i      (d_tx_req[d]),
        .tx_req_valid_i(d_tx_req_valid[d]),
        .tx_req_ready_o(d_tx_req_ready[d]),
        .tx_rsp_i      (d_tx_rsp[d]),
        .tx_rsp_valid_i(d_tx_rsp_valid[d]),
        .tx_rsp_ready_o(d_tx_rsp_ready[d]),
        .tx_dat_i      (d_tx_dat[d]),
        .tx_dat_valid_i(d_tx_dat_valid[d]),
        .tx_dat_ready_o(d_tx_dat_ready[d]),
        .tx_snp_i      (d_tx_snp[d]),
        .tx_snp_tgt_i  ('0),
        .tx_snp_valid_i(d_tx_snp_valid[d]),
        .tx_snp_ready_o(d_tx_snp_ready[d])
    );
  end

  ////////////////////////////////////////////////////////////////////////////////////////////////
  // The agents
  ////////////////////////////////////////////////////////////////////////////////////////////////

  for (genvar r = 0; r < Requesters; r++) begin : gen_requester
    localparam int unsigned D = RequesterIndex[r];

    chi_rn_core #(
        .Name(RequesterName[r])
    ) i_rn (
        .clk_i (clk),
        .rst_ni(rst_n),

        .rx_rsp_i      (d_rx_rsp[D]),
        .rx_rsp_valid_i(d_rx_rsp_valid[D]),
        .rx_rsp_ready_o(d_rx_rsp_ready[D]),
        .rx_dat_i      (d_rx_dat[D]),
        .rx_dat_valid_i(d_rx_dat_valid[D]),
        .rx_dat_ready_o(d_rx_dat_ready[D]),
        .rx_snp_i      (d_rx_snp[D]),
        .rx_snp_valid_i(d_rx_snp_valid[D]),
        .rx_snp_ready_o(d_rx_snp_ready[D]),

        .tx_req_o      (d_tx_req[D]),
        .tx_req_valid_o(d_tx_req_valid[D]),
        .tx_req_ready_i(d_tx_req_ready[D]),
        .tx_rsp_o      (d_tx_rsp[D]),
        .tx_rsp_valid_o(d_tx_rsp_valid[D]),
        .tx_rsp_ready_i(d_tx_rsp_ready[D]),
        .tx_dat_o      (d_tx_dat[D]),
        .tx_dat_valid_o(d_tx_dat_valid[D]),
        .tx_dat_ready_i(d_tx_dat_ready[D])
    );

    // A request node receives no requests, and sends no snoops.
    assign d_rx_req_ready[D] = 1'b1;
    assign d_tx_snp[D]       = '0;
    assign d_tx_snp_valid[D] = 1'b0;
  end

  for (genvar h = 0; h < Homes; h++) begin : gen_home
    localparam int unsigned D = HomeIndex[h];

    chi_hn_core #(
        .Name(HomeName[h])
    ) i_hn (
        .clk_i (clk),
        .rst_ni(rst_n),

        .rx_req_i      (d_rx_req[D]),
        .rx_req_valid_i(d_rx_req_valid[D]),
        .rx_req_ready_o(d_rx_req_ready[D]),
        .rx_rsp_i      (d_rx_rsp[D]),
        .rx_rsp_valid_i(d_rx_rsp_valid[D]),
        .rx_rsp_ready_o(d_rx_rsp_ready[D]),
        .rx_dat_i      (d_rx_dat[D]),
        .rx_dat_valid_i(d_rx_dat_valid[D]),
        .rx_dat_ready_o(d_rx_dat_ready[D]),

        .tx_rsp_o      (d_tx_rsp[D]),
        .tx_rsp_valid_o(d_tx_rsp_valid[D]),
        .tx_rsp_ready_i(d_tx_rsp_ready[D]),
        .tx_dat_o      (d_tx_dat[D]),
        .tx_dat_valid_o(d_tx_dat_valid[D]),
        .tx_dat_ready_i(d_tx_dat_ready[D]),
        .tx_snp_o      (d_tx_snp[D]),
        .tx_snp_valid_o(d_tx_snp_valid[D]),
        .tx_snp_ready_i(d_tx_snp_ready[D])
    );

    // A home node here receives no snoops and sends no requests.
    assign d_rx_snp_ready[D] = 1'b1;
    assign d_tx_req[D]       = '0;
    assign d_tx_req_valid[D] = 1'b0;
  end

  // The four ports with nothing on them: take everything, send nothing. Silence
  // that is chosen rather than undriven.
  for (genvar d = 0; d < Devices; d++) begin : gen_unused
    if (d != RNF0_INDEX && d != RNF1_INDEX && d != RNF2_INDEX && d != RNF3_INDEX &&
        d != RNF4_INDEX && d != RNF5_INDEX && d != RNF6_INDEX && d != RNF7_INDEX &&
        d != HNF0_INDEX && d != HNF1_INDEX && d != HNF2_INDEX && d != HNF3_INDEX) begin : gen_idle
      assign d_rx_req_ready[d] = 1'b1;
      assign d_rx_rsp_ready[d] = 1'b1;
      assign d_rx_dat_ready[d] = 1'b1;
      assign d_rx_snp_ready[d] = 1'b1;
      assign d_tx_req[d]       = '0;
      assign d_tx_rsp[d]       = '0;
      assign d_tx_dat[d]       = '0;
      assign d_tx_snp[d]       = '0;
      assign d_tx_req_valid[d] = 1'b0;
      assign d_tx_rsp_valid[d] = 1'b0;
      assign d_tx_dat_valid[d] = 1'b0;
      assign d_tx_snp_valid[d] = 1'b0;
    end
  end

  ////////////////////////////////////////////////////////////////////////////////////////////////
  // The verdict
  ////////////////////////////////////////////////////////////////////////////////////////////////

  int unsigned completed;
  int unsigned failures;

  function automatic bit everyone_idle();
    for (int unsigned r = 0; r < Requesters; r++) if (!chi_rn_idle(requester[r])) return 1'b0;
    for (int unsigned h = 0; h < Homes; h++) if (chi_hn_outstanding(home[h]) != 0) return 1'b0;
    return 1'b1;
  endfunction

  // Work is given out in phases, and the phases are the point.
  //
  // A requester with eight transactions in flight will happily issue a read of
  // a line whose write is still outstanding, and CHI does not order two
  // independent transactions to one address -- so the read is served from
  // memory that has not been written yet and comes back as the fill byte. That
  // is a hazard a real requester handles and this model does not, because
  // handling it is cache work and this fabric is transport.
  //
  // So the testbench sequences instead: every write lands before any read is
  // asked for. Doing it the other way round produced exactly the failure
  // described above, at the second beat of a line, which is worth knowing is
  // what that looks like.
  task automatic run_phase(input string what);
    while (!everyone_idle()) @(posedge clk);
    repeat (50) @(posedge clk);
    if (!everyone_idle()) $fatal(1, "%s did not settle", what);
  endtask

  initial begin
    failures = 0;

    wait (rst_n);
    repeat (8) @(posedge clk);

    for (int unsigned r = 0; r < Requesters; r++) begin
      for (int unsigned line = 0; line < LinesPerRequester; line++) begin
        chi_rn_write(requester[r], 64'(address_of(r, line)), LineBytes,
                     home_for(address_of(r, line)));
      end
    end
    run_phase("the writes");

    for (int unsigned r = 0; r < Requesters; r++) begin
      for (int unsigned line = 0; line < LinesPerRequester; line++) begin
        chi_rn_read(requester[r], 64'(address_of(r, line)), LineBytes,
                    home_for(address_of(r, line)));
      end
    end
    run_phase("the reads");

    // The third kind of transaction, so a test that claims to cover them does.
    for (int unsigned r = 0; r < Requesters; r++) begin
      chi_rn_dataless(requester[r], 64'(address_of(r, 0)), home_for(address_of(r, 0)));
    end
    run_phase("the dataless requests");
    // A little longer, so that anything still in flight arrives and is counted
    // as unexpected rather than not arriving at all.
    repeat (200) @(posedge clk);

    completed = 0;
    for (int unsigned r = 0; r < Requesters; r++) begin
      completed += chi_rn_completed(requester[r]);

      if (chi_rn_mismatches(requester[r]) != 0) begin
        $error("%s: %0d bytes came back wrong", RequesterName[r], chi_rn_mismatches(requester[r]));
        failures++;
      end
      if (chi_rn_unexpected(requester[r]) != 0) begin
        $error("%s: %0d flits arrived that it never asked for", RequesterName[r],
               chi_rn_unexpected(requester[r]));
        failures++;
      end
      if (chi_rn_outstanding(requester[r]) != 0) begin
        $error("%s: %0d transactions never finished", RequesterName[r],
               chi_rn_outstanding(requester[r]));
        failures++;
      end
      // Every byte this requester wrote is in memory where it addressed it.
      // The check that the fabric put the bytes somewhere in particular rather
      // than merely somewhere.
      if (!chi_rn_check_memory(requester[r], memory)) begin
        $error("%s: memory does not hold what it wrote", RequesterName[r]);
        failures++;
      end
    end

    for (int unsigned h = 0; h < Homes; h++) begin
      if (chi_hn_unsupported(home[h]) != 0) begin
        $error("%s: %0d requests it does not implement", HomeName[h],
               chi_hn_unsupported(home[h]));
        failures++;
      end
      if (chi_hn_outstanding(home[h]) != 0) begin
        $error("%s: %0d transactions still open", HomeName[h], chi_hn_outstanding(home[h]));
        failures++;
      end
    end

    // 16 writes, 16 reads and one dataless request each.
    if (completed != Requesters * (2 * LinesPerRequester + 1)) begin
      $error("%0d transactions completed, expected %0d", completed,
             Requesters * (2 * LinesPerRequester + 1));
      failures++;
    end

    if (failures != 0) $fatal(1, "%0d checks failed", failures);

    $display("%0d transactions across the mesh: %0d requesters, %0d home nodes, no mismatches",
             completed, Requesters, Homes);
    $finish;
  end

  initial begin
    wait (rst_n);
    repeat (Timeout) @(posedge clk);
    $display("timeout: completed so far:");
    for (int unsigned r = 0; r < Requesters; r++) begin
      $display("  %s: %0d done, %0d outstanding", RequesterName[r], chi_rn_completed(requester[r]),
               chi_rn_outstanding(requester[r]));
    end
    $fatal(1, "the system did not settle");
  end

endmodule
