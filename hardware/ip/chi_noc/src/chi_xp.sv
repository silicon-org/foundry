// A crosspoint: four channel classes, six ports, one tile of the mesh.
//
// There is very little logic here. `chi_xp_channel` is the switch, and this
// module instantiates it four times -- once per CHI channel class -- with the
// five numbers each class needs, then splits and reassembles the port structs
// that carry them. What the four instances share is a clock and a floorplan
// tile, and nothing else: separate buffers, separate credits, separate
// arbitration. See //hardware/ip/chi_noc/README.md for why that is what makes
// the protocol deadlock-free here.
//
// The CHI issue is not visible below except through chi_noc_flit_pkg, which
// computes every width and offset this file passes down.
module chi_xp
  import chi_noc_pkg::CHI_XP_PORTS;
  import chi_noc_flit_pkg::chi_xp_port_t;
#(
    // Where this crosspoint sits. Routing compares a flit's target against it.
    parameter int unsigned XIndex = 0,
    parameter int unsigned YIndex = 0,

    // Which of the six ports exist: East, West, North, South, P0, P1, from bit
    // 0 up. An edge crosspoint has fewer, and a disabled port costs no logic.
    parameter logic [CHI_XP_PORTS-1:0] PortEnable = '1,

    // L-Credits per input port per class, which is also the buffer depth behind
    // them. Six because the credit round trip is five cycles and a link below
    // that underruns; see chi_xp_channel, where the number is explained, and
    // the README, where it is measured.
    //
    // One number for all four classes, although DAT flits are six times the
    // width of RSP and so cost six times as much per credit. Nothing yet argues
    // for spending that difference, and a per-class depth is a knob to add when
    // something does.
    parameter int unsigned Credits = 10
) (
    input logic clk_i,
    input logic rst_ni,

    // What each neighbour sends us, and the credits it grants for what we send
    // it. `tx_o` is the mirror. A link is one assignment of the second to the
    // first; see any generated `*_noc.sv`.
    input  chi_xp_port_t [CHI_XP_PORTS-1:0] rx_i,
    output chi_xp_port_t [CHI_XP_PORTS-1:0] tx_o
);

  localparam int unsigned Ports = CHI_XP_PORTS;

  ////////////////////////////////////////////////////////////////////////////////////////////////
  // One channel class
  //
  // The four instances differ only in the five numbers and in which member of
  // the port struct they read, so the wiring is written once as a macro. Written
  // out four times it would be four places to make the same mistake.
  //
  // `__lcrd` is the class's L-Credit-return predicate: opcode zero on every
  // channel, but the opcode sits in a different place in each, and chi_pkg
  // answers it per channel from the typed struct.
  ////////////////////////////////////////////////////////////////////////////////////////////////

`define CHI_XP_CLASS(__name, __width, __tgt_off, __member, __opcode, __lcrd)                      \
  logic [Ports-1:0]              __name``_rx_flitv;                                               \
  logic [Ports-1:0][__width-1:0] __name``_rx_flit;                                                \
  logic [Ports-1:0]              __name``_rx_is_lcrd;                                             \
  logic [Ports-1:0]              __name``_rx_lcrdv;                                               \
  logic [Ports-1:0]              __name``_tx_lcrdv;                                               \
  logic [Ports-1:0]              __name``_tx_flitpend;                                            \
  logic [Ports-1:0]              __name``_tx_flitv;                                               \
  logic [Ports-1:0][__width-1:0] __name``_tx_flit;                                                \
                                                                                                  \
  for (genvar p = 0; p < Ports; p++) begin : gen_``__name``_unpack                                \
    assign __name``_rx_flitv[p]   = rx_i[p].__member.flitv;                                       \
    assign __name``_rx_flit[p]    = rx_i[p].__member.flit;                                        \
    assign __name``_rx_is_lcrd[p] = chi_pkg::__lcrd(rx_i[p].__member.flit.__opcode);              \
    assign __name``_tx_lcrdv[p]   = rx_i[p].__member``_lcrdv;                                     \
  end                                                                                             \
                                                                                                  \
  chi_xp_channel #(                                                                               \
      .FlitWidth  (__width),                                                                      \
      .TgtIdOffset(__tgt_off),                                                                    \
      .TgtIdWidth (chi_noc_flit_pkg::CHI_XP_TGTID_WIDTH),                                         \
      .QosOffset  (chi_noc_flit_pkg::CHI_XP_QOS_OFFSET),                                          \
      .QosWidth   (chi_noc_flit_pkg::CHI_XP_QOS_WIDTH),                                           \
      .XIndex     (XIndex),                                                                       \
      .YIndex     (YIndex),                                                                       \
      .PortEnable (PortEnable),                                                                   \
      .Credits    (Credits)                                                                       \
  ) i_``__name (                                                                                  \
      .clk_i,                                                                                     \
      .rst_ni,                                                                                    \
      .rx_flitv_i         (__name``_rx_flitv),                                                    \
      .rx_flit_i          (__name``_rx_flit),                                                     \
      .rx_is_lcrd_return_i(__name``_rx_is_lcrd),                                                  \
      .rx_lcrdv_o         (__name``_rx_lcrdv),                                                    \
      .tx_lcrdv_i         (__name``_tx_lcrdv),                                                    \
      .tx_flitpend_o      (__name``_tx_flitpend),                                                 \
      .tx_flitv_o         (__name``_tx_flitv),                                                    \
      .tx_flit_o          (__name``_tx_flit)                                                      \
  );

  // A snoop's opcode is one level further in, under the routing header the
  // fabric prepended; the other three are the CHI flit itself.
  `CHI_XP_CLASS(req, chi_noc_flit_pkg::CHI_XP_REQ_WIDTH, chi_noc_flit_pkg::CHI_XP_REQ_TGTID_OFFSET,
                req, opcode, chi_req_is_lcrd_return)
  `CHI_XP_CLASS(rsp, chi_noc_flit_pkg::CHI_XP_RSP_WIDTH, chi_noc_flit_pkg::CHI_XP_RSP_TGTID_OFFSET,
                rsp, opcode, chi_rsp_is_lcrd_return)
  `CHI_XP_CLASS(dat, chi_noc_flit_pkg::CHI_XP_DAT_WIDTH, chi_noc_flit_pkg::CHI_XP_DAT_TGTID_OFFSET,
                dat, opcode, chi_dat_is_lcrd_return)
  `CHI_XP_CLASS(snp, chi_noc_flit_pkg::CHI_XP_SNP_WIDTH, chi_noc_flit_pkg::CHI_XP_SNP_TGTID_OFFSET,
                snp, snp.opcode, chi_snp_is_lcrd_return)

`undef CHI_XP_CLASS

  ////////////////////////////////////////////////////////////////////////////////////////////////
  // Back into port structs
  //
  // One block per port drives the whole of `tx_o[p]`, so each bit of the output
  // has exactly one source and it is obvious which.
  ////////////////////////////////////////////////////////////////////////////////////////////////

  for (genvar p = 0; p < Ports; p++) begin : gen_pack
    always_comb begin
      tx_o[p].req.flitpend = req_tx_flitpend[p];
      tx_o[p].req.flitv    = req_tx_flitv[p];
      tx_o[p].req.flit     = req_tx_flit[p];

      tx_o[p].rsp.flitpend = rsp_tx_flitpend[p];
      tx_o[p].rsp.flitv    = rsp_tx_flitv[p];
      tx_o[p].rsp.flit     = rsp_tx_flit[p];

      tx_o[p].dat.flitpend = dat_tx_flitpend[p];
      tx_o[p].dat.flitv    = dat_tx_flitv[p];
      tx_o[p].dat.flit     = dat_tx_flit[p];

      tx_o[p].snp.flitpend = snp_tx_flitpend[p];
      tx_o[p].snp.flitv    = snp_tx_flitv[p];
      tx_o[p].snp.flit     = snp_tx_flit[p];

      // Credits we grant for what arrives on this port.
      tx_o[p].req_lcrdv = req_rx_lcrdv[p];
      tx_o[p].rsp_lcrdv = rsp_rx_lcrdv[p];
      tx_o[p].dat_lcrdv = dat_rx_lcrdv[p];
      tx_o[p].snp_lcrdv = snp_rx_lcrdv[p];
    end
  end

endmodule
