// How anything attaches to the mesh.
//
// A crosspoint device port speaks `chi_xp_port_t`: four channels of flits and
// the L-Credits for four more, all in two structs. A device speaks CHI flits
// with valid/ready, because that is what an agent, a home node or a core has.
// This is the translation, and it is the only place the two meet.
//
// It is also where the **snoop's fabric header** is put on and taken off. A CHI
// SNP flit carries no TgtID -- a snoop is sent on the link to the node being
// snooped -- so the mesh prepends one to route by, and what a device hands over
// or receives is a CHI SNP flit and nothing else. A sender supplies the target
// alongside the flit; a receiver never sees it. See
// //hardware/ip/chi_noc/README.md.
module chi_noc_device_port
  import chi_noc_flit_pkg::chi_xp_port_t;
#(
    // L-Credits granted on each inbound channel, and so the depth of the buffer
    // behind them. Six for the reason chi_xp_channel gives: the credit round
    // trip is five cycles and anything below that underruns.
    parameter int unsigned Credits = 6
) (
    input logic clk_i,
    input logic rst_ni,

    // The crosspoint side. `xp_i` is what the mesh sends this device plus the
    // credits it grants for what the device sends; `xp_o` is the mirror.
    input  chi_xp_port_t xp_i,
    output chi_xp_port_t xp_o,

    ////////////////////////////////////////////////////////////////////////////////////////////////
    // From the mesh, to the device.
    ////////////////////////////////////////////////////////////////////////////////////////////////

    output chi_pkg::chi_req_t rx_req_o,
    output logic              rx_req_valid_o,
    input  logic              rx_req_ready_i,

    output chi_pkg::chi_rsp_t rx_rsp_o,
    output logic              rx_rsp_valid_o,
    input  logic              rx_rsp_ready_i,

    output chi_pkg::chi_dat_t rx_dat_o,
    output logic              rx_dat_valid_o,
    input  logic              rx_dat_ready_i,

    // The routing header is gone by here: this is a CHI snoop.
    output chi_pkg::chi_snp_t rx_snp_o,
    output logic              rx_snp_valid_o,
    input  logic              rx_snp_ready_i,

    ////////////////////////////////////////////////////////////////////////////////////////////////
    // From the device, into the mesh.
    ////////////////////////////////////////////////////////////////////////////////////////////////

    input  chi_pkg::chi_req_t tx_req_i,
    input  logic              tx_req_valid_i,
    output logic              tx_req_ready_o,

    input  chi_pkg::chi_rsp_t tx_rsp_i,
    input  logic              tx_rsp_valid_i,
    output logic              tx_rsp_ready_o,

    input  chi_pkg::chi_dat_t tx_dat_i,
    input  logic              tx_dat_valid_i,
    output logic              tx_dat_ready_o,

    // A snoop needs somewhere to go, and the flit cannot say. Only a home node
    // drives this; everything else ties it off.
    input  chi_pkg::chi_snp_t          tx_snp_i,
    input  chi_noc_pkg::chi_noc_nodeid_t tx_snp_tgt_i,
    input  logic                       tx_snp_valid_i,
    output logic                       tx_snp_ready_o
);

  // The mesh never powers a link down; see chi_xp_channel for why activation
  // belongs at a boundary that has something to power down.
  chi_pkg::chi_link_state_e link_state;
  assign link_state = chi_pkg::CHI_LINK_RUN;

  // One receiver and one transmitter per class. The four differ only in a width
  // and a member, so they are written once -- which is also the difference four
  // copies would get wrong.
`define CHI_NOC_DEVICE_CHANNEL(__member, __flit_t, __lcrd, __tx_flit, __opcode)                   \
  chi_link_rx_channel #(                                                                          \
      .FlitWidth($bits(__flit_t)),                                                                \
      .Credits  (Credits)                                                                         \
  ) i_rx_``__member (                                                                             \
      .clk_i,                                                                                     \
      .rst_ni,                                                                                    \
      .state_i         (link_state),                                                              \
      .flitpend_i      (xp_i.__member.flitpend),                                                  \
      .flitv_i         (xp_i.__member.flitv),                                                     \
      .flit_i          (xp_i.__member.flit),                                                      \
      .is_lcrd_return_i(chi_pkg::__lcrd(xp_i.__member.flit.__opcode)),                            \
      .lcrdv_o         (xp_o.__member``_lcrdv),                                                   \
      .flit_o          (rx_``__member``_raw),                                                     \
      .valid_o         (rx_``__member``_valid_o),                                                 \
      .ready_i         (rx_``__member``_ready_i),                                                 \
      .outstanding_o   ()                                                                         \
  );                                                                                              \
                                                                                                  \
  chi_link_tx_channel #(                                                                          \
      .FlitWidth($bits(__flit_t))                                                                 \
  ) i_tx_``__member (                                                                             \
      .clk_i,                                                                                     \
      .rst_ni,                                                                                    \
      .state_i   (link_state),                                                                    \
      .flit_i    (__tx_flit),                                                                     \
      .valid_i   (tx_``__member``_valid_i),                                                       \
      .ready_o   (tx_``__member``_ready_o),                                                       \
      .flitpend_o(xp_o.__member.flitpend),                                                        \
      .flitv_o   (xp_o.__member.flitv),                                                           \
      .flit_o    (xp_o.__member.flit),                                                            \
      .lcrdv_i   (xp_i.__member``_lcrdv),                                                         \
      .credits_o ()                                                                               \
  );

  ////////////////////////////////////////////////////////////////////////////////////////////////
  // REQ, RSP and DAT: the fabric flit is the CHI flit
  ////////////////////////////////////////////////////////////////////////////////////////////////

  chi_pkg::chi_req_t rx_req_raw;
  chi_pkg::chi_rsp_t rx_rsp_raw;
  chi_pkg::chi_dat_t rx_dat_raw;

  `CHI_NOC_DEVICE_CHANNEL(req, chi_pkg::chi_req_t, chi_req_is_lcrd_return, tx_req_i, opcode)
  `CHI_NOC_DEVICE_CHANNEL(rsp, chi_pkg::chi_rsp_t, chi_rsp_is_lcrd_return, tx_rsp_i, opcode)
  `CHI_NOC_DEVICE_CHANNEL(dat, chi_pkg::chi_dat_t, chi_dat_is_lcrd_return, tx_dat_i, opcode)

  assign rx_req_o = rx_req_raw;
  assign rx_rsp_o = rx_rsp_raw;
  assign rx_dat_o = rx_dat_raw;

  ////////////////////////////////////////////////////////////////////////////////////////////////
  // SNP: the fabric flit is the CHI flit plus somewhere to send it
  ////////////////////////////////////////////////////////////////////////////////////////////////

  chi_noc_flit_pkg::chi_noc_snp_flit_t rx_snp_raw;
  chi_noc_flit_pkg::chi_noc_snp_flit_t tx_snp_fabric;

  // Put the header on. This is the only place it is written, and the target
  // comes from the home node that decided to snoop rather than from the flit.
  always_comb begin
    tx_snp_fabric.tgt_id = chi_pkg::chi_nodeid_t'(tx_snp_tgt_i);
    tx_snp_fabric.snp    = tx_snp_i;
  end

  `CHI_NOC_DEVICE_CHANNEL(snp, chi_noc_flit_pkg::chi_noc_snp_flit_t, chi_snp_is_lcrd_return,
                          tx_snp_fabric, snp.opcode)

  // And take it off again, so that what a request node receives is a CHI SNP
  // flit with nothing added to it.
  assign rx_snp_o = rx_snp_raw.snp;

`undef CHI_NOC_DEVICE_CHANNEL

endmodule
