// A XiangShan cluster, a clock and a reset.
//
// The clock and the reset live here rather than in C++, which is the whole
// reason the model is built with --timing. Two things follow from that and both
// are worth the cost: the testbench reads like hardware rather than like a
// program poking a model, and it runs unchanged under a commercial simulator,
// because nothing in it is Verilator's.
//
// At this milestone the CHI port is held inactive and the cluster has nowhere to
// fetch from. That is deliberate: this is the milestone that finds out what it
// costs to Verilate 1868 generated modules, and mixing that discovery with a
// protocol bring-up would leave two unknowns in one failure. //hardware/vip/chi
// arrives on this port next.

module xs_cluster_tb #(
  // 1 GHz, which is a round number rather than a target. Nothing here is
  // timing-closed and no result depends on it.
  // A half period rather than a period, because `time` is an integer type and
  // `ClkPeriod / 2` is integer division: at a coarse enough time precision it
  // rounds to zero and `forever #0` is an infinite loop in zero time -- which
  // is reported, at some distance from the cause, as an inactive region that
  // would not converge. Naming the half period removes the division and the
  // question.
  parameter time ClkHalfPeriod = 1ns,

  // Cycles held in reset, and cycles run afterwards. Both are small: the
  // cluster has no memory behind its CHI port yet, so once the core has asked
  // for its first instruction and been ignored, nothing further happens.
  parameter int unsigned ResetCycles = 20,
  parameter int unsigned RunCycles = 1000,

  // Where the core would fetch its first instruction. XiangShan's memory starts
  // at 0x8000_0000 and this is the value //hardware/vip/chi's memory model will
  // be loaded at; it is here now so the request the core makes is the request a
  // later milestone has to answer.
  parameter logic [47:0] ResetVector = 48'h8000_0000,

  // This cluster's identity on a system that does not exist yet. Both are
  // inputs to the design rather than parameters, so a system with several
  // clusters gives them different values without regenerating anything.
  parameter logic [5:0]  HartId = 6'd0,
  parameter logic [10:0] NodeId = 11'd0
);

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

  logic bus_error;
  logic wfi;
  logic critical_error;
  logic hart_in_reset;

  // Nothing drives the far side of the link yet, so the interconnect's half of
  // it reads as an interconnect that is not there: no acknowledgement of the
  // cluster's activation request, and no credits. The cluster raises
  // linkactivereq and waits, which is the correct thing for it to do.
  always_comb chi_rx = '0;

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
  // What this milestone checks
  //
  // Not much, and deliberately so. The cluster comes out of reset, asks to
  // activate its CHI link, gets no answer, and stops. What is being established
  // is that the model builds, elaborates, and runs -- and the two things that
  // would say otherwise are a core reporting a fatal internal error, and a
  // simulation that never reaches its own end.
  ////////////////////////////////////////////////////////////////////////////////////////////////

  int unsigned cycle;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) cycle <= 0;
    else cycle <= cycle + 1;
  end

  // critical_error_o is the core saying it has reached a state it cannot
  // continue from. There is no configuration of this testbench in which that is
  // expected, so it fails the test wherever it happens.
  always_ff @(posedge clk) begin
    if (rst_n)
      assert (!critical_error)
      else $fatal(1, "cycle %0d: the core asserted critical_error_o", cycle);
  end

  // The cluster must ask to bring its link up. If it never does, either reset
  // is not reaching the L2 or the port is not connected to what this testbench
  // thinks it is -- and with the far side idle, this is the only sign of life
  // the port can give.
  logic saw_linkactivereq;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) saw_linkactivereq <= 1'b0;
    else if (chi_tx.tx_linkactivereq) saw_linkactivereq <= 1'b1;
  end

  initial begin
    wait (rst_n);
    repeat (RunCycles) @(posedge clk);

    assert (saw_linkactivereq)
    else
      $fatal(1, "%0d cycles out of reset and the cluster never raised tx_linkactivereq",
             RunCycles);

    $display("xs_cluster_tb: %0d cycles, link activation requested, no critical error", cycle);
    $finish;
  end

endmodule
