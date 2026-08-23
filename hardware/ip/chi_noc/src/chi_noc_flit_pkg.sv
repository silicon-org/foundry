// What the fabric carries, and the handful of numbers a crosspoint needs to
// know about it.
//
// **This is the only file in the fabric that depends on the CHI issue.**
// Everything else works on `logic [FlitWidth-1:0]` and five integers, so moving
// from Issue E.b to Issue H is a change here and nowhere else. That is what
// "structured for H" has to mean if it is to mean anything.
//
// The five numbers per channel class are, per //hardware/ip/chi_noc/README.md:
// the flit width, where TgtID sits and how wide it is, and where QoS sits and
// how wide it is. A crosspoint reads exactly those fields -- it never decodes an
// opcode and never sees a struct.
package chi_noc_flit_pkg;

  ////////////////////////////////////////////////////////////////////////////////////////////////
  // The fabric flit
  //
  // For REQ, RSP and DAT a fabric flit is the CHI flit: it already carries the
  // TgtID the mesh routes on, at no cost.
  //
  // A snoop does not. CHI sends a SNP on the link to the node being snooped, so
  // the flit never needed a target and does not have one -- inside a mesh it
  // must. So the fabric prepends one, written at the HN-facing ingress and
  // stripped at the RN-facing egress, and what arrives at a request node is a
  // CHI SNP flit and nothing else. OpenNoC's home node does exactly this
  // (hnf_link_txsnp_wrap.v:174).
  ////////////////////////////////////////////////////////////////////////////////////////////////

  typedef chi_pkg::chi_req_t chi_noc_req_flit_t;
  typedef chi_pkg::chi_rsp_t chi_noc_rsp_flit_t;
  typedef chi_pkg::chi_dat_t chi_noc_dat_flit_t;

  // Declared MSB first, so `snp` is at bit 0 and `tgt_id` sits immediately above
  // it -- which is why the SNP TgtID offset below is the CHI flit's width.
  typedef struct packed {
    chi_pkg::chi_nodeid_t tgt_id;
    chi_pkg::chi_snp_t    snp;
  } chi_noc_snp_flit_t;

  localparam int unsigned CHI_XP_REQ_WIDTH = $bits(chi_noc_req_flit_t);
  localparam int unsigned CHI_XP_RSP_WIDTH = $bits(chi_noc_rsp_flit_t);
  localparam int unsigned CHI_XP_DAT_WIDTH = $bits(chi_noc_dat_flit_t);
  localparam int unsigned CHI_XP_SNP_WIDTH = $bits(chi_noc_snp_flit_t);

  ////////////////////////////////////////////////////////////////////////////////////////////////
  // Where the two fields a crosspoint reads live
  //
  // `chi_typedef.svh` declares its structs MSB first with QoS last, which is
  // XSCache's packing order, so QoS is at bit 0 on every channel and TgtID sits
  // immediately above it on the three that have one. OpenNoC's crosspoint
  // defaults its offset parameter to 4 for the same reason.
  //
  // Derived rather than written as 4 and 115, and then checked against the typed
  // structs in //hardware/ip/chi_noc/test -- a constant that agrees with the
  // layout today and silently stops agreeing is exactly the failure this fabric
  // cannot detect at run time.
  ////////////////////////////////////////////////////////////////////////////////////////////////

  localparam int unsigned CHI_XP_QOS_OFFSET = 0;
  localparam int unsigned CHI_XP_QOS_WIDTH = chi_pkg::CHI_QOS_WIDTH;

  localparam int unsigned CHI_XP_TGTID_WIDTH = chi_pkg::CHI_NODEID_WIDTH;

  localparam int unsigned CHI_XP_REQ_TGTID_OFFSET = chi_pkg::CHI_QOS_WIDTH;
  localparam int unsigned CHI_XP_RSP_TGTID_OFFSET = chi_pkg::CHI_QOS_WIDTH;
  localparam int unsigned CHI_XP_DAT_TGTID_OFFSET = chi_pkg::CHI_QOS_WIDTH;
  // The header the fabric added, which begins where the CHI flit ends.
  localparam int unsigned CHI_XP_SNP_TGTID_OFFSET = $bits(chi_pkg::chi_snp_t);

  ////////////////////////////////////////////////////////////////////////////////////////////////
  // A crosspoint port
  //
  // One struct each way. A port sends four channels of flits and grants the
  // L-Credits for the four it receives, so wiring one crosspoint to the next is
  // a single assignment rather than thirty -- see any generated `*_noc.sv`.
  //
  // The direction convention is what makes that work: `tx_o[EAST]` carries the
  // flits this crosspoint sends east *and* the credits it grants for flits
  // arriving from the east. The neighbour reads both out of its `rx_i[WEST]`.
  ////////////////////////////////////////////////////////////////////////////////////////////////

  `define CHI_XP_CHANNEL_T(__name, __flit_t) \
    typedef struct packed {                  \
      logic     flitpend;                    \
      logic     flitv;                       \
      __flit_t  flit;                        \
    } __name;

  `CHI_XP_CHANNEL_T(chi_xp_req_chan_t, chi_noc_req_flit_t)
  `CHI_XP_CHANNEL_T(chi_xp_rsp_chan_t, chi_noc_rsp_flit_t)
  `CHI_XP_CHANNEL_T(chi_xp_dat_chan_t, chi_noc_dat_flit_t)
  `CHI_XP_CHANNEL_T(chi_xp_snp_chan_t, chi_noc_snp_flit_t)

  `undef CHI_XP_CHANNEL_T

  typedef struct packed {
    chi_xp_req_chan_t req;
    chi_xp_rsp_chan_t rsp;
    chi_xp_dat_chan_t dat;
    chi_xp_snp_chan_t snp;

    // Credits for what this port receives, one per class.
    logic req_lcrdv;
    logic rsp_lcrdv;
    logic dat_lcrdv;
    logic snp_lcrdv;
  } chi_xp_port_t;

endpackage : chi_noc_flit_pkg
