// One XiangShan core with its own L2, wrapped for integration.
//
// What the generator emits is called XSTop even in this configuration, has four
// clock inputs, a DFT bundle, a trace-encoder bundle and active-high resets. What
// a system integrator wants is a block with one clock, one reset, a CHI port and
// the interrupts. This wrapper is the difference between those two, and nothing
// else: no glue logic, no arbitration, no address decoding. Anything with
// behaviour belongs in a module of its own where it can be tested.
//
// The three tie-offs below are the wrapper's real content. Each one is a decision
// that would otherwise be made silently, in a hurry, at the point where the first
// system gets assembled.
module xs_cluster (
  // Every clock domain the core has is driven from this one. The generated top
  // takes four -- core, NoC, SoC and CLINT -- because upstream's L2 can sit
  // behind a CHI asynchronous bridge and cross into an interconnect running at
  // its own rate. Until there is an interconnect to be asynchronous to, one
  // domain is the honest description, and the bridge degenerates into a
  // same-clock FIFO.
  input  logic          clk_i,
  // Asynchronous, active-low, as everything else in this repository is. The
  // generated top wants active-high async resets, which is the only conversion
  // this module does.
  input  logic          rst_ni,

  // Identity. hart_id_i lands in mhartid; node_id_i is this cluster's CHI node
  // ID, which the interconnect's address map has to agree with.
  input  logic [5:0]    hart_id_i,
  input  logic [10:0]   node_id_i,
  // Where the core fetches its first instruction.
  input  logic [47:0]   reset_vector_i,

  // mtime, from wherever the system keeps it. The core has no timer of its own in
  // this configuration, so a system that leaves this invalid has a hart whose
  // rdtime never advances.
  input  logic          time_valid_i,
  input  logic [63:0]   time_i,

  // Interrupts. Named for the CSR bits they drive rather than for the diplomacy
  // ports they arrive on, because the generated names -- clint_0_0, plic_1_0 --
  // say nothing about which is which.
  input  logic          msip_i,
  input  logic          mtip_i,
  input  logic          meip_i,
  input  logic          seip_i,
  input  logic          debug_int_i,
  input  logic          nmi_31_i,
  input  logic          nmi_43_i,
  // Raised by the L2's bus error unit, and routed back in as nmi_31 inside the
  // core, so a system can both see it and be interrupted by it.
  output logic          bus_error_o,

  // Status.
  output logic          wfi_o,
  output logic          critical_error_o,
  input  logic          hart_reset_req_i,
  output logic          hart_in_reset_o,

  // CHI-E.b, as the two link bundles //hardware/ip/chi declares.
  //
  // A CHI link is six channels and a handshake, and it is not valid/ready: a
  // transmitter may send only while it holds an L-Credit, the receiver grants
  // credits by pulsing LCRDV, and there is no ready anywhere. So the split here
  // is by direction rather than by channel -- everything this cluster drives,
  // and everything the interconnect drives -- and each bundle carries both the
  // flits its side sends and the credits it returns for the flits it receives.
  //
  // These were thirty separate ports carrying upstream's widths, on the
  // reasoning that a CHI package belongs with the interconnect that defines the
  // address map and the node IDs, and that inventing one here would fix those
  // choices before anyone had made them. The package now exists and fixes
  // neither: it describes a specification, the address map is still nobody's,
  // and node_id_i is still an input.
  output chi_pkg::chi_rn_link_tx_t chi_tx_o,
  input  chi_pkg::chi_rn_link_rx_t chi_rx_i,

  // The trace-encoder interface, as the RISC-V efficient-trace specification
  // defines it: up to three retirement groups per cycle, and the cause and
  // privilege of a trap when one is taken.
  //
  // Brought out rather than tied off, because it is the only window into what
  // the core is doing that does not involve a waveform. A testbench watching
  // these can say "trapped at 0x8000_0008 with cause 2" instead of "stopped",
  // and that difference is most of a bring-up.
  //
  // trace_enable_i is the encoder telling the core to produce them;
  // trace_stall_i is the encoder telling it to hold off. A system with no
  // encoder ties the first low and the second low too.
  input  logic          trace_enable_i,
  input  logic          trace_stall_i,
  // Three groups, packed: group i occupies bit i of _valid and _ilastsize, and
  // the i'th slice of the others.
  output logic [2:0]    trace_valid_o,
  output logic [149:0]  trace_iaddr_o,
  output logic [11:0]   trace_itype_o,
  output logic [23:0]   trace_iretire_o,
  output logic [2:0]    trace_ilastsize_o,
  // The trap, when itype says one was taken.
  output logic [63:0]   trace_cause_o,
  output logic [49:0]   trace_tval_o,
  output logic [2:0]    trace_priv_o,
  output logic [63:0]   trace_mstatus_o,

  // The IMSIC's configuration port: a 32-bit AXI4 slave through which the system
  // writes message-signalled interrupts to this hart. Narrow and low-traffic,
  // which is why it is AXI and not CHI.
  output logic          imsic_awready_o,
  input  logic          imsic_awvalid_i,
  input  logic [15:0]   imsic_awid_i,
  input  logic [31:0]   imsic_awaddr_i,
  input  logic [7:0]    imsic_awlen_i,
  input  logic [2:0]    imsic_awsize_i,
  input  logic [1:0]    imsic_awburst_i,
  input  logic          imsic_awlock_i,
  input  logic [3:0]    imsic_awcache_i,
  input  logic [2:0]    imsic_awprot_i,
  input  logic [3:0]    imsic_awqos_i,
  output logic          imsic_wready_o,
  input  logic          imsic_wvalid_i,
  input  logic [31:0]   imsic_wdata_i,
  input  logic [3:0]    imsic_wstrb_i,
  input  logic          imsic_wlast_i,
  input  logic          imsic_bready_i,
  output logic          imsic_bvalid_o,
  output logic [15:0]   imsic_bid_o,
  output logic [1:0]    imsic_bresp_o,
  output logic          imsic_arready_o,
  input  logic          imsic_arvalid_i,
  input  logic [15:0]   imsic_arid_i,
  input  logic [31:0]   imsic_araddr_i,
  input  logic [7:0]    imsic_arlen_i,
  input  logic [2:0]    imsic_arsize_i,
  input  logic [1:0]    imsic_arburst_i,
  input  logic          imsic_arlock_i,
  input  logic [3:0]    imsic_arcache_i,
  input  logic [2:0]    imsic_arprot_i,
  input  logic [3:0]    imsic_arqos_i,
  input  logic          imsic_rready_i,
  output logic          imsic_rvalid_o,
  output logic [15:0]   imsic_rid_o,
  output logic [31:0]   imsic_rdata_o,
  output logic [1:0]    imsic_rresp_o,
  output logic          imsic_rlast_o
);

  logic rst;
  assign rst = ~rst_ni;

  // The generated top declares its flit ports as bare vectors, so a package
  // whose structs were a bit wider or narrower would connect here and decode
  // into nonsense downstream. What stops that is
  // //hardware/ip/chi/test:chi_pkg_test, which holds the four widths XSTop
  // declares -- 162, 73, 422, 115 -- next to the ones chi_pkg computes and the
  // ones CHIron computes, and fails if any of the three disagree.
  //
  // Not checked here, and the reason is worth writing down: `$error` inside a
  // generate block is a *warning* to Verilator, `%Warning-USERERROR`, and this
  // repository's lint runs with warnings non-fatal. A check written that way
  // passes whatever the widths are. See tasks/lessons.md.

  XSTop i_xs_top (
    // Clocks and resets: one domain, see above.
    .clock       (clk_i),
    .reset       (rst),
    .noc_clock   (clk_i),
    .noc_reset   (rst),
    .soc_clock   (clk_i),
    .soc_reset   (rst),
    .clint_clock (clk_i),
    .clint_reset (rst),

    .io_hartId       (hart_id_i),
    .io_nodeID       (node_id_i),
    .io_riscv_rst_vec(reset_vector_i),

    .io_clintTime_valid (time_valid_i),
    .io_clintTime_bits  (time_i),

    // clint_0_0 is msip and clint_0_1 is mtip; plic port 0 is meip and port 1 is
    // seip; nmi_0_0 is nmi_31 and nmi_0_1 is nmi_43. All four pairs are
    // orderings in upstream's Chisel, invisible in the generated names, and
    // swapping either pair produces hardware that boots and then misbehaves in a
    // way no simulation of this module would show.
    .clint_0_0 (msip_i),
    .clint_0_1 (mtip_i),
    .plic_0_0  (meip_i),
    .plic_1_0  (seip_i),
    .debug_0_0 (debug_int_i),
    .nmi_0_0   (nmi_31_i),
    .nmi_0_1   (nmi_43_i),
    .beu_0_0   (bus_error_o),

    .io_riscv_wfi           (wfi_o),
    .io_riscv_critical_error(critical_error_o),
    .io_hartResetReq        (hart_reset_req_i),
    .io_hartIsInReset       (hart_in_reset_o),

    .io_chi_txsactive (chi_tx_o.txsactive),
    .io_chi_rxsactive (chi_rx_i.rxsactive),
    .io_chi_syscoreq  (chi_tx_o.syscoreq),
    .io_chi_syscoack  (chi_rx_i.syscoack),

    .io_chi_tx_linkactivereq (chi_tx_o.tx_linkactivereq),
    .io_chi_tx_linkactiveack (chi_rx_i.tx_linkactiveack),
    .io_chi_tx_req_flitpend  (chi_tx_o.txreq.flitpend),
    .io_chi_tx_req_flitv     (chi_tx_o.txreq.flitv),
    .io_chi_tx_req_flit      (chi_tx_o.txreq.flit),
    .io_chi_tx_req_lcrdv     (chi_rx_i.txreq_lcrdv),
    .io_chi_tx_rsp_flitpend  (chi_tx_o.txrsp.flitpend),
    .io_chi_tx_rsp_flitv     (chi_tx_o.txrsp.flitv),
    .io_chi_tx_rsp_flit      (chi_tx_o.txrsp.flit),
    .io_chi_tx_rsp_lcrdv     (chi_rx_i.txrsp_lcrdv),
    .io_chi_tx_dat_flitpend  (chi_tx_o.txdat.flitpend),
    .io_chi_tx_dat_flitv     (chi_tx_o.txdat.flitv),
    .io_chi_tx_dat_flit      (chi_tx_o.txdat.flit),
    .io_chi_tx_dat_lcrdv     (chi_rx_i.txdat_lcrdv),

    .io_chi_rx_linkactivereq (chi_rx_i.rx_linkactivereq),
    .io_chi_rx_linkactiveack (chi_tx_o.rx_linkactiveack),
    .io_chi_rx_rsp_flitpend  (chi_rx_i.rxrsp.flitpend),
    .io_chi_rx_rsp_flitv     (chi_rx_i.rxrsp.flitv),
    .io_chi_rx_rsp_flit      (chi_rx_i.rxrsp.flit),
    .io_chi_rx_rsp_lcrdv     (chi_tx_o.rxrsp_lcrdv),
    .io_chi_rx_dat_flitpend  (chi_rx_i.rxdat.flitpend),
    .io_chi_rx_dat_flitv     (chi_rx_i.rxdat.flitv),
    .io_chi_rx_dat_flit      (chi_rx_i.rxdat.flit),
    .io_chi_rx_dat_lcrdv     (chi_tx_o.rxdat_lcrdv),
    .io_chi_rx_snp_flitpend  (chi_rx_i.rxsnp.flitpend),
    .io_chi_rx_snp_flitv     (chi_rx_i.rxsnp.flitv),
    .io_chi_rx_snp_flit      (chi_rx_i.rxsnp.flit),
    .io_chi_rx_snp_lcrdv     (chi_tx_o.rxsnp_lcrdv),

    .imsic_axi4_awready (imsic_awready_o),
    .imsic_axi4_awvalid (imsic_awvalid_i),
    .imsic_axi4_awid    (imsic_awid_i),
    .imsic_axi4_awaddr  (imsic_awaddr_i),
    .imsic_axi4_awlen   (imsic_awlen_i),
    .imsic_axi4_awsize  (imsic_awsize_i),
    .imsic_axi4_awburst (imsic_awburst_i),
    .imsic_axi4_awlock  (imsic_awlock_i),
    .imsic_axi4_awcache (imsic_awcache_i),
    .imsic_axi4_awprot  (imsic_awprot_i),
    .imsic_axi4_awqos   (imsic_awqos_i),
    .imsic_axi4_wready  (imsic_wready_o),
    .imsic_axi4_wvalid  (imsic_wvalid_i),
    .imsic_axi4_wdata   (imsic_wdata_i),
    .imsic_axi4_wstrb   (imsic_wstrb_i),
    .imsic_axi4_wlast   (imsic_wlast_i),
    .imsic_axi4_bready  (imsic_bready_i),
    .imsic_axi4_bvalid  (imsic_bvalid_o),
    .imsic_axi4_bid     (imsic_bid_o),
    .imsic_axi4_bresp   (imsic_bresp_o),
    .imsic_axi4_arready (imsic_arready_o),
    .imsic_axi4_arvalid (imsic_arvalid_i),
    .imsic_axi4_arid    (imsic_arid_i),
    .imsic_axi4_araddr  (imsic_araddr_i),
    .imsic_axi4_arlen   (imsic_arlen_i),
    .imsic_axi4_arsize  (imsic_arsize_i),
    .imsic_axi4_arburst (imsic_arburst_i),
    .imsic_axi4_arlock  (imsic_arlock_i),
    .imsic_axi4_arcache (imsic_arcache_i),
    .imsic_axi4_arprot  (imsic_arprot_i),
    .imsic_axi4_arqos   (imsic_arqos_i),
    .imsic_axi4_rready  (imsic_rready_i),
    .imsic_axi4_rvalid  (imsic_rvalid_o),
    .imsic_axi4_rid     (imsic_rid_o),
    .imsic_axi4_rdata   (imsic_rdata_o),
    .imsic_axi4_rresp   (imsic_rresp_o),
    .imsic_axi4_rlast   (imsic_rlast_o),

    // Test controls, tied to their inactive values. A real chip drives these from
    // a test controller; leaving them out of the wrapper's interface means the
    // day DFT arrives, adding them is a visible change here rather than a
    // scattered set of new ports on every enclosing level.
    .io_dft_ram_hold        (1'b0),
    .io_dft_ram_bypass      (1'b0),
    .io_dft_ram_bp_clken    (1'b0),
    .io_dft_ram_aux_clk     (1'b0),
    .io_dft_ram_aux_ckbp    (1'b0),
    .io_dft_ram_mcp_hold    (1'b0),
    .io_dft_ram_ctl         (64'b0),
    .io_dft_cgen            (1'b0),
    // Active low: holding this at 0 would keep the SRAMs' reset logic asserted.
    .io_dft_reset_lgc_rst_n (1'b1),
    .io_dft_reset_mode      (1'b0),
    .io_dft_reset_scan_mode (1'b0),

    .io_traceCoreInterface_fromEncoder_enable (trace_enable_i),
    .io_traceCoreInterface_fromEncoder_stall  (trace_stall_i),
    .io_traceCoreInterface_toEncoder_cause    (trace_cause_o),
    .io_traceCoreInterface_toEncoder_tval     (trace_tval_o),
    .io_traceCoreInterface_toEncoder_priv     (trace_priv_o),
    .io_traceCoreInterface_toEncoder_mstatus  (trace_mstatus_o),
    .io_traceCoreInterface_toEncoder_valid    (trace_valid_o),
    .io_traceCoreInterface_toEncoder_iaddr    (trace_iaddr_o),
    .io_traceCoreInterface_toEncoder_itype    (trace_itype_o),
    .io_traceCoreInterface_toEncoder_iretire  (trace_iretire_o),
    .io_traceCoreInterface_toEncoder_ilastsize(trace_ilastsize_o)
  );

endmodule
