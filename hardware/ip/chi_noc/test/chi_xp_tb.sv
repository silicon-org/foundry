// A whole crosspoint: four channel classes at once.
//
// `chi_xp_channel` is where the logic is and `chi_xp_channel_tb` is where it is
// tested. This module is wiring -- four instances, and the splitting and
// reassembling of the port structs around them -- so what is checked here is
// what wiring can get wrong:
//
//   - a class reading the wrong member of the port struct, so REQ flits arrive
//     on RSP,
//   - an L-Credit wired to the wrong class or the wrong direction, so a channel
//     never starts,
//   - the SNP TgtID offset applied to the wrong class, so snoops misroute while
//     everything else works.
//
// All three are silent at run time and none is visible to a single-class test,
// which is why this exists in addition to and not instead of the other one.
//
// The four classes are driven together with content that says which class it
// came from, so cross-talk shows up as a payload arriving where it should not
// rather than as a count that happens to match.
module chi_xp_tb #(
    parameter time ClkHalfPeriod = 1ns,
    parameter int unsigned Credits = 4,
    parameter int unsigned Timeout = 5000
);

  import chi_noc_pkg::*;
  import chi_noc_flit_pkg::*;

  localparam int unsigned Ports = CHI_XP_PORTS;
  localparam int unsigned XIndex = 1;
  localparam int unsigned YIndex = 1;

  // Where a flit is injected and where it should come out. West to east is a
  // turn every class is allowed to take.
  localparam int unsigned SrcPort = CHI_XP_WEST;
  localparam int unsigned DstPort = CHI_XP_EAST;

  // A NodeID one hop east of the crosspoint under test.
  function automatic chi_noc_nodeid_t east_target();
    return chi_noc_node_id(chi_noc_x_t'(XIndex + 1), chi_noc_y_t'(YIndex), 3'd0);
  endfunction

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
  // The crosspoint, and a link partner on every port
  ////////////////////////////////////////////////////////////////////////////////////////////////

  chi_xp_port_t [Ports-1:0] xp_rx;
  chi_xp_port_t [Ports-1:0] xp_tx;

  chi_xp #(
      .XIndex    (XIndex),
      .YIndex    (YIndex),
      .PortEnable('1),
      .Credits   (Credits)
  ) i_dut (
      .clk_i (clk),
      .rst_ni(rst_n),
      .rx_i  (xp_rx),
      .tx_o  (xp_tx)
  );

  // Per class and per port: a transmitter feeding the crosspoint's receiver, and
  // a receiver draining its transmitter. Written once as a macro because the
  // four classes differ only in a width and a struct member -- which is exactly
  // the sort of difference this testbench exists to catch, so it must not be
  // hand-written four times.
`define CHI_XP_TB_PARTNER(__name, __width, __member)                                              \
  logic                 __name``_inject_valid[Ports];                                             \
  logic                 __name``_inject_ready[Ports];                                             \
  logic [__width-1:0]   __name``_inject_flit [Ports];                                             \
  logic [Ports-1:0]                __name``_eject_valid;                                          \
  logic [Ports-1:0][__width-1:0]   __name``_eject_flit;                                           \
                                                                                                  \
  for (genvar p = 0; p < Ports; p++) begin : gen_``__name``_partner                               \
    chi_link_tx_channel #(                                                                        \
        .FlitWidth(__width)                                                                       \
    ) i_inject (                                                                                  \
        .clk_i     (clk),                                                                         \
        .rst_ni    (rst_n),                                                                       \
        .state_i   (chi_pkg::CHI_LINK_RUN),                                                       \
        .flit_i    (__name``_inject_flit[p]),                                                     \
        .valid_i   (__name``_inject_valid[p]),                                                    \
        .ready_o   (__name``_inject_ready[p]),                                                    \
        .flitpend_o(xp_rx[p].__member.flitpend),                                                  \
        .flitv_o   (xp_rx[p].__member.flitv),                                                     \
        .flit_o    (xp_rx[p].__member.flit),                                                      \
        .lcrdv_i   (xp_tx[p].__member``_lcrdv),                                                   \
        .credits_o ()                                                                             \
    );                                                                                            \
                                                                                                  \
    chi_link_rx_channel #(                                                                        \
        .FlitWidth(__width),                                                                      \
        .Credits  (Credits)                                                                       \
    ) i_eject (                                                                                   \
        .clk_i           (clk),                                                                   \
        .rst_ni          (rst_n),                                                                 \
        .state_i         (chi_pkg::CHI_LINK_RUN),                                                 \
        .flitpend_i      (xp_tx[p].__member.flitpend),                                            \
        .flitv_i         (xp_tx[p].__member.flitv),                                               \
        .flit_i          (xp_tx[p].__member.flit),                                                \
        .is_lcrd_return_i(xp_tx[p].__member.flitv && (xp_tx[p].__member.flit == '0)),             \
        .lcrdv_o         (xp_rx[p].__member``_lcrdv),                                             \
        .flit_o          (__name``_eject_flit[p]),                                                \
        .valid_o         (__name``_eject_valid[p]),                                               \
        .ready_i         (1'b1),                                                                  \
        .outstanding_o   ()                                                                       \
    );                                                                                            \
  end

  `CHI_XP_TB_PARTNER(req, CHI_XP_REQ_WIDTH, req)
  `CHI_XP_TB_PARTNER(rsp, CHI_XP_RSP_WIDTH, rsp)
  `CHI_XP_TB_PARTNER(dat, CHI_XP_DAT_WIDTH, dat)
  `CHI_XP_TB_PARTNER(snp, CHI_XP_SNP_WIDTH, snp)

`undef CHI_XP_TB_PARTNER

  ////////////////////////////////////////////////////////////////////////////////////////////////
  // What arrived, per class and per port
  ////////////////////////////////////////////////////////////////////////////////////////////////

  int unsigned req_seen[Ports];
  int unsigned rsp_seen[Ports];
  int unsigned dat_seen[Ports];
  int unsigned snp_seen[Ports];

  chi_pkg::chi_req_t   req_last;
  chi_pkg::chi_rsp_t   rsp_last;
  chi_pkg::chi_dat_t   dat_last;
  chi_noc_snp_flit_t   snp_last;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int unsigned p = 0; p < Ports; p++) begin
        req_seen[p] <= 0;
        rsp_seen[p] <= 0;
        dat_seen[p] <= 0;
        snp_seen[p] <= 0;
      end
    end else begin
      for (int unsigned p = 0; p < Ports; p++) begin
        if (req_eject_valid[p]) begin
          req_seen[p] <= req_seen[p] + 1;
          req_last <= req_eject_flit[p];
        end
        if (rsp_eject_valid[p]) begin
          rsp_seen[p] <= rsp_seen[p] + 1;
          rsp_last <= rsp_eject_flit[p];
        end
        if (dat_eject_valid[p]) begin
          dat_seen[p] <= dat_seen[p] + 1;
          dat_last <= dat_eject_flit[p];
        end
        if (snp_eject_valid[p]) begin
          snp_seen[p] <= snp_seen[p] + 1;
          snp_last <= snp_eject_flit[p];
        end
      end
    end
  end

  ////////////////////////////////////////////////////////////////////////////////////////////////
  // One flit per class, all four at once
  ////////////////////////////////////////////////////////////////////////////////////////////////

  // Distinct per class, so a flit that surfaces on the wrong one is obvious.
  localparam logic [11:0] ReqTxnId = 12'h111;
  localparam logic [11:0] RspTxnId = 12'h222;
  localparam logic [11:0] DatTxnId = 12'h333;
  localparam logic [11:0] SnpTxnId = 12'h444;

  chi_pkg::chi_req_t req_flit;
  chi_pkg::chi_rsp_t rsp_flit;
  chi_pkg::chi_dat_t dat_flit;
  chi_noc_snp_flit_t snp_flit;

  initial begin
    for (int unsigned p = 0; p < Ports; p++) begin
      req_inject_valid[p] = 1'b0;
      rsp_inject_valid[p] = 1'b0;
      dat_inject_valid[p] = 1'b0;
      snp_inject_valid[p] = 1'b0;
      req_inject_flit[p]  = '0;
      rsp_inject_flit[p]  = '0;
      dat_inject_flit[p]  = '0;
      snp_inject_flit[p]  = '0;
    end

    // A non-zero opcode on every class, and not by accident: opcode zero *is*
    // the L-Credit return, so a flit left at zero is flow control and the
    // crosspoint is right to consume it and send nothing on.
    req_flit = '0;
    req_flit.opcode = chi_pkg::CHI_REQ_READ_NO_SNP;
    req_flit.qos = 4'h8;
    req_flit.tgt_id = east_target();
    req_flit.txn_id = ReqTxnId;

    rsp_flit = '0;
    rsp_flit.opcode = chi_pkg::CHI_RSP_COMP_ACK;
    rsp_flit.qos = 4'h8;
    rsp_flit.tgt_id = east_target();
    rsp_flit.txn_id = RspTxnId;

    dat_flit = '0;
    dat_flit.opcode = chi_pkg::CHI_DAT_COMP_DATA;
    dat_flit.qos = 4'h8;
    dat_flit.tgt_id = east_target();
    dat_flit.txn_id = DatTxnId;

    // A snoop carries no TgtID of its own; the fabric's header is what routes
    // it, and this is the only class where the two are different fields.
    snp_flit = '0;
    snp_flit.snp.opcode = chi_pkg::CHI_SNP_ONCE;
    snp_flit.tgt_id = east_target();
    snp_flit.snp.qos = 4'h8;
    snp_flit.snp.txn_id = SnpTxnId;

    wait (rst_n);
    repeat (8) @(posedge clk);

    @(negedge clk);
    req_inject_flit[SrcPort]  = req_flit;
    rsp_inject_flit[SrcPort]  = rsp_flit;
    dat_inject_flit[SrcPort]  = dat_flit;
    snp_inject_flit[SrcPort]  = snp_flit;
    req_inject_valid[SrcPort] = 1'b1;
    rsp_inject_valid[SrcPort] = 1'b1;
    dat_inject_valid[SrcPort] = 1'b1;
    snp_inject_valid[SrcPort] = 1'b1;

    // Each class has its own credits, so each is accepted when its own
    // transmitter says so.
    while (!(req_inject_ready[SrcPort] && rsp_inject_ready[SrcPort] &&
             dat_inject_ready[SrcPort] && snp_inject_ready[SrcPort])) begin
      @(posedge clk);
    end
    @(negedge clk);
    req_inject_valid[SrcPort] = 1'b0;
    rsp_inject_valid[SrcPort] = 1'b0;
    dat_inject_valid[SrcPort] = 1'b0;
    snp_inject_valid[SrcPort] = 1'b0;

    repeat (40) @(posedge clk);

    ////////////////////////////////////////////////////////////////////////////////////////////
    // One flit out of each class, at the destination and nowhere else
    ////////////////////////////////////////////////////////////////////////////////////////////

    for (int unsigned p = 0; p < Ports; p++) begin
      automatic int unsigned want = (p == DstPort) ? 1 : 0;
      if (req_seen[p] != want) $fatal(1, "REQ: port %0d saw %0d flits, wanted %0d", p, req_seen[p], want);
      if (rsp_seen[p] != want) $fatal(1, "RSP: port %0d saw %0d flits, wanted %0d", p, rsp_seen[p], want);
      if (dat_seen[p] != want) $fatal(1, "DAT: port %0d saw %0d flits, wanted %0d", p, dat_seen[p], want);
      if (snp_seen[p] != want) $fatal(1, "SNP: port %0d saw %0d flits, wanted %0d", p, snp_seen[p], want);
    end

    // Each class carried its own flit and not another's, which is what catches
    // a member wired to the wrong channel.
    if (req_last.txn_id != ReqTxnId) $fatal(1, "REQ carried TxnID %03h", req_last.txn_id);
    if (rsp_last.txn_id != RspTxnId) $fatal(1, "RSP carried TxnID %03h", rsp_last.txn_id);
    if (dat_last.txn_id != DatTxnId) $fatal(1, "DAT carried TxnID %03h", dat_last.txn_id);
    if (snp_last.snp.txn_id != SnpTxnId) $fatal(1, "SNP carried TxnID %03h", snp_last.snp.txn_id);

    // The snoop's routing header survived the crossing intact. The fabric adds
    // it at the boundary and strips it there; a crosspoint must pass it through.
    if (snp_last.tgt_id != east_target()) begin
      $fatal(1, "SNP lost its fabric header: %03h", snp_last.tgt_id);
    end

    $display("chi_xp: four classes, four flits, no cross-talk");
    $finish;
  end

  initial begin
    wait (rst_n);
    repeat (Timeout) @(posedge clk);
    $fatal(1, "timeout: req=%0d rsp=%0d dat=%0d snp=%0d at the destination", req_seen[DstPort],
           rsp_seen[DstPort], dat_seen[DstPort], snp_seen[DstPort]);
  end

endmodule
