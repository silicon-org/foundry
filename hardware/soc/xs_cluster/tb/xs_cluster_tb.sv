// A XiangShan cluster, a clock and a reset.
//
// The clock and the reset live here rather than in C++, which is the whole
// reason the model is built with --timing. Two things follow from that and both
// are worth the cost: the testbench reads like hardware rather than like a
// program poking a model, and it runs unchanged under a commercial simulator,
// because nothing in it is Verilator's.
//
// On the far side of the CHI port is a chi_hn_agent: a SystemVerilog link layer
// and, through DPI, the C++ home node in //hardware/vip/chi. The memory behind
// it, the program in that memory and the address whose being written ends the
// run are all set up below, in the first initial block.
//
// No C++ in this directory: Verilator's `--main` generates the evaluation loop,
// leaving only what a commercial simulator also needs.

`include "chi_hn_dpi.svh"
`include "vip_dpi.svh"

module xs_cluster_tb #(
  // Nothing here is timing-closed and no result depends on the period.
  //
  // A half period rather than a period, because `time` is an integer type and
  // `ClkPeriod / 2` is integer division: at a coarse enough time precision it
  // rounds to zero and `forever #0` is an infinite loop in zero time -- which
  // is reported, at some distance from the cause, as an inactive region that
  // would not converge. Naming the half period removes the division and the
  // question.
  parameter time ClkHalfPeriod = 1ns,

  parameter int unsigned ResetCycles = 20,

  // Generous. The program is six instructions and the run ends around cycle
  // 1120, but almost all of that is before the core does anything: CoupledL2
  // walks its whole directory to clear it, so the first fetch does not leave the
  // cluster until about cycle 1050.
  parameter int unsigned RunCycles = 4000,

  // Bringing the link up is a handshake and a few credits, so if it has not
  // happened in this many cycles it is not going to.
  parameter int unsigned LinkTimeoutCycles = 200,

  // Where the core fetches its first instruction. XiangShan's PMA makes
  // everything from 0x8000_0000 upwards cacheable and executable, which is where
  // the program below is loaded.
  parameter logic [47:0] ResetVector = 48'h8000_0000,

  // The home node this testbench creates and the agent finds.
  parameter string HomeNodeName = "chi.hn",
  parameter int unsigned HomeNodeId = 32'h2A,
  parameter int unsigned LineBytes = 64,

  // Where the program says it is finished, and what it writes there.
  //
  // Below 0x8000_0000 and so outside XiangShan's cacheable range, which is the
  // point: a store to a cacheable address sits in the L1 until something evicts
  // it, and a test that waits for an eviction is a test waiting on a replacement
  // policy. An uncacheable store leaves the cluster as a WriteNoSnp the moment
  // it retires.
  parameter logic [47:0] ToHost = 48'h2000_0000,
  parameter logic [31:0] ToHostValue = 32'd1,

  // This cluster's identity on a system that does not exist yet. Both are
  // inputs to the design rather than parameters, so a system with several
  // clusters gives them different values without regenerating anything.
  parameter logic [5:0]  HartId = 6'd0,
  parameter logic [10:0] NodeId = 11'd0
);

  ////////////////////////////////////////////////////////////////////////////////////////////////
  // The program, and the memory it runs out of
  //
  // Machine code rather than assembly. Six instructions do not justify a RISC-V
  // toolchain in the build graph, and an instruction beside its encoding is more
  // reviewable than a rule that runs an assembler nobody reads the output of. If
  // a test ever needs a program worth debugging, that is when the toolchain
  // earns its place.
  //
  //   lui  x1, 0x20000     x1 = the tohost address
  //   li   x2, 1           addi x2, x0, 1
  //   nop                  addi x0, x0, 0
  //   nop
  //   sw   x2, 0(x1)       the store this test waits for
  //   1: j 1b              and then forever
  //
  // The two nops are the `while (1) nop` this was meant to run; the store is
  // what lets the test say it ran, rather than say that nothing went wrong.
  ////////////////////////////////////////////////////////////////////////////////////////////////

  localparam int unsigned ProgramWords = 6;
  localparam logic [31:0] Program[ProgramWords] = '{
      32'h200000B7,  // lui  x1, 0x20000
      32'h00100113,  // addi x2, x0, 1
      32'h00000013,  // nop
      32'h00000013,  // nop
      32'h0020A023,  // sw   x2, 0(x1)
      32'h0000006F   // j    .
  };

  chandle memory;
  chandle home_node;

  initial begin
    memory = vip_mem_create();
    for (int unsigned i = 0; i < ProgramWords; i++)
      vip_mem_load_word(memory, 64'(ResetVector) + 64'(i) * 4, Program[i]);

    // What ends the run, and what would fail it: the store landing with the
    // wrong value is as much a result as it not landing at all.
    vip_mem_expect_write(memory, 64'(ToHost), ToHostValue);

    home_node = chi_hn_create(HomeNodeName, HomeNodeId, LineBytes, memory);
  end

  ////////////////////////////////////////////////////////////////////////////////////////////////
  // Waveforms
  //
  // `$dumpvars` rather than a Verilator API, so this works on other simulators.
  // A plusarg rather than a parameter, because wanting a waveform is a property
  // of the run. Only the `_traced` target has tracing compiled in; elsewhere
  // these tasks do nothing.
  //
  //   bazel run //hardware/soc/xs_cluster/tb:xs_cluster_tb_traced -- \
  //       +dump +dumpfile=/tmp/xs.fst
  //
  // Whole hierarchy: 1868 modules, but the run is short enough that the FST is
  // ~3 MB. Narrow the scope if a longer program changes that.
  ////////////////////////////////////////////////////////////////////////////////////////////////

  initial begin
    string dumpfile;
    if ($test$plusargs("dump")) begin
      if (!$value$plusargs("dumpfile=%s", dumpfile)) dumpfile = "xs_cluster_tb.fst";
      $display("xs_cluster_tb: dumping waveforms to %s", dumpfile);
      $dumpfile(dumpfile);
      $dumpvars(0, xs_cluster_tb);
    end
  end

  ////////////////////////////////////////////////////////////////////////////////////////////////
  // Clock and reset
  ////////////////////////////////////////////////////////////////////////////////////////////////

  logic clk;
  logic rst_n;

  initial begin
    clk = 1'b0;
    forever #ClkHalfPeriod clk = ~clk;
  end

  // Asynchronous and active low, as everything in this repository is. Released
  // off a falling edge so that the first rising edge the design sees is a clean
  // one.
  initial begin
    rst_n = 1'b0;
    repeat (ResetCycles) @(negedge clk);
    rst_n = 1'b1;
  end

  ////////////////////////////////////////////////////////////////////////////////////////////////
  // mtime
  //
  // The cluster has no timer of its own in this configuration. A free-running
  // counter is not what a real system would supply -- mtime is meant to be
  // shared by every hart -- but it is what makes rdtime advance, and a hart
  // whose rdtime never advances is a hart that hangs in a delay loop.
  ////////////////////////////////////////////////////////////////////////////////////////////////

  logic [63:0] mtime;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) mtime <= '0;
    else mtime <= mtime + 1;
  end

  ////////////////////////////////////////////////////////////////////////////////////////////////
  // The cluster
  ////////////////////////////////////////////////////////////////////////////////////////////////

  chi_pkg::chi_rn_link_tx_t chi_tx;
  chi_pkg::chi_rn_link_rx_t chi_rx;

  logic [2:0]   trace_valid;
  logic [149:0] trace_iaddr;
  logic [11:0]  trace_itype;
  logic [23:0]  trace_iretire;
  logic [63:0]  trace_cause;
  logic [49:0]  trace_tval;
  logic [2:0]   trace_priv;

  logic bus_error;
  logic wfi;
  logic critical_error;
  logic hart_in_reset;

  chi_pkg::chi_link_state_e chi_rn_tx_state;
  chi_pkg::chi_link_state_e chi_rn_rx_state;

  chi_hn_agent #(
    .Name (HomeNodeName)
  ) i_chi_hn (
    .clk_i         (clk),
    .rst_ni        (rst_n),
    .rn_i          (chi_tx),
    .hn_o          (chi_rx),
    .rn_tx_state_o (chi_rn_tx_state),
    .rn_rx_state_o (chi_rn_rx_state)
  );

  xs_cluster i_xs_cluster (
    .clk_i   (clk),
    .rst_ni  (rst_n),

    .hart_id_i       (HartId),
    .node_id_i       (NodeId),
    .reset_vector_i  (ResetVector),

    .time_valid_i (1'b1),
    .time_i       (mtime),

    // No interrupt controller yet. Each of these is a real port on a real
    // system and every one is quiet here.
    .msip_i           (1'b0),
    .mtip_i           (1'b0),
    .meip_i           (1'b0),
    .seip_i           (1'b0),
    .debug_int_i      (1'b0),
    .nmi_31_i         (1'b0),
    .nmi_43_i         (1'b0),
    .bus_error_o      (bus_error),

    .wfi_o             (wfi),
    .critical_error_o  (critical_error),
    .hart_reset_req_i  (1'b0),
    .hart_in_reset_o   (hart_in_reset),

    .chi_tx_o (chi_tx),
    .chi_rx_i (chi_rx),

    // The core's own account of what it retired and what it trapped on.
    .trace_enable_i    (1'b1),
    .trace_stall_i     (1'b0),
    .trace_valid_o     (trace_valid),
    .trace_iaddr_o     (trace_iaddr),
    .trace_itype_o     (trace_itype),
    .trace_iretire_o   (trace_iretire),
    .trace_ilastsize_o (),
    .trace_cause_o     (trace_cause),
    .trace_tval_o      (trace_tval),
    .trace_priv_o      (trace_priv),
    .trace_mstatus_o   (),

    // The IMSIC's configuration port. Tied off rather than brought out: an AXI
    // manager for it is what //hardware/vip/axi is for, and it is the cheapest
    // test of whether the agents' shared layers are really protocol-agnostic.
    .imsic_awready_o (),
    .imsic_awvalid_i (1'b0),
    .imsic_awid_i    ('0),
    .imsic_awaddr_i  ('0),
    .imsic_awlen_i   ('0),
    .imsic_awsize_i  ('0),
    .imsic_awburst_i ('0),
    .imsic_awlock_i  (1'b0),
    .imsic_awcache_i ('0),
    .imsic_awprot_i  ('0),
    .imsic_awqos_i   ('0),
    .imsic_wready_o  (),
    .imsic_wvalid_i  (1'b0),
    .imsic_wdata_i   ('0),
    .imsic_wstrb_i   ('0),
    .imsic_wlast_i   (1'b0),
    .imsic_bready_i  (1'b0),
    .imsic_bvalid_o  (),
    .imsic_bid_o     (),
    .imsic_bresp_o   (),
    .imsic_arready_o (),
    .imsic_arvalid_i (1'b0),
    .imsic_arid_i    ('0),
    .imsic_araddr_i  ('0),
    .imsic_arlen_i   ('0),
    .imsic_arsize_i  ('0),
    .imsic_arburst_i ('0),
    .imsic_arlock_i  (1'b0),
    .imsic_arcache_i ('0),
    .imsic_arprot_i  ('0),
    .imsic_arqos_i   ('0),
    .imsic_rready_i  (1'b0),
    .imsic_rvalid_o  (),
    .imsic_rid_o     (),
    .imsic_rdata_o   (),
    .imsic_rresp_o   (),
    .imsic_rlast_o   ()
  );

  ////////////////////////////////////////////////////////////////////////////////////////////////
  // What this testbench establishes
  //
  // The cluster leaves reset, brings its CHI link up, fetches its reset vector
  // over it and executes the program it is served, ending with the store to
  // ToHost. That covers the credit layer, the DPI boundary, the flit encodings
  // and the protocol model.
  //
  // Executing at all took one field: the home node was leaving CHI DataCheck at
  // zero and CoupledL2 checks it. See tasks/xs-cluster-tb.md.
  ////////////////////////////////////////////////////////////////////////////////////////////////

  int unsigned cycle;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) cycle <= 0;
    else cycle <= cycle + 1;
  end

  // The core's own account of what it retired and what it trapped on.
  localparam logic [3:0] TraceItypeException = 4'd1;
  localparam logic [3:0] TraceItypeInterrupt = 4'd2;

  always_ff @(posedge clk) begin
    if (rst_n) begin
      for (int unsigned g = 0; g < 3; g++) begin
        if (trace_valid[g]) begin
          $display("[trace %0d] group %0d: pc=%011h itype=%0d iretire=%0d priv=%0d", cycle, g,
                   trace_iaddr[g*50 +: 50], trace_itype[g*4 +: 4], trace_iretire[g*8 +: 8],
                   trace_priv);
          if (trace_itype[g*4 +: 4] == TraceItypeException ||
              trace_itype[g*4 +: 4] == TraceItypeInterrupt)
            $display("[trace %0d]   trap: cause=%0d tval=%013h", cycle, trace_cause, trace_tval);
        end
      end
    end
  end

  // Both directions of the link have to come up before anything can happen.
  logic link_running;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) link_running <= 1'b0;
    else if (chi_rn_tx_state == chi_pkg::CHI_LINK_RUN &&
             chi_rn_rx_state == chi_pkg::CHI_LINK_RUN)
      link_running <= 1'b1;
  end

  initial begin
    wait (rst_n);
    repeat (LinkTimeoutCycles) @(posedge clk);
    assert (link_running)
    else
      $fatal(1, "%0d cycles out of reset and the CHI link is in %s / %s", LinkTimeoutCycles,
             chi_rn_tx_state.name(), chi_rn_rx_state.name());
    $display("xs_cluster_tb: CHI link running at cycle %0d", cycle);
  end

  // The core's first instruction fetch. It arrives around a thousand cycles
  // after reset, which is not the core being slow: CoupledL2 walks its whole
  // directory clearing it before it will serve anything.
  initial begin
    wait (rst_n);
    while (chi_hn_reads(home_node) == 0) @(posedge clk);
    $display("xs_cluster_tb: the core fetched its reset vector at cycle %0d", cycle);

    // Served from the memory this testbench loaded, and served correctly --
    // //hardware/vip/chi/test:chi_hn_agent_read_line_test checks the bytes, and
    // this checks that it is this core's request being served.
    repeat (8) @(posedge clk);
    assert (chi_hn_unsupported(home_node) == 0)
    else
      $fatal(1, "the home node was sent %0d requests it does not implement",
             chi_hn_unsupported(home_node));

    // Not the end of the test: being served a line says nothing about whether
    // the core runs it. The ToHost watchpoint above is what ends the run.
  end

  always_ff @(posedge clk) begin
    if (rst_n && vip_test_done()) begin
      $display("xs_cluster_tb: done at cycle %0d", cycle);
      // A generated main() always returns zero, so this $fatal is the only
      // thing that can fail the test.
      assert (!vip_test_failed())
      else $fatal(1, "cycle %0d: the run ended on a failure", cycle);
      $finish;
    end
  end

  // What a longer run has to answer, and what it will fail on until it is
  // answered. Not reachable today: the test above concludes first.
  always_ff @(posedge clk) begin
    if (rst_n)
      assert (!critical_error)
      else
        $fatal(1, "cycle %0d: critical_error_o -- a trap with mnstatus.NMIE still zero", cycle);
  end

  initial begin
    wait (rst_n);
    repeat (RunCycles) @(posedge clk);
    $fatal(1, "%0d cycles and nothing concluded; link %s / %s, %0d reads served", RunCycles,
           chi_rn_tx_state.name(), chi_rn_rx_state.name(), chi_hn_reads(home_node));
  end

endmodule
