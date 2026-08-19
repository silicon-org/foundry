// AMBA CHI, Issue E.b: channel and link typedefs.
//
// Two layers, and keeping them apart is the point of the file.
//
// The channel macros describe a *flit* -- the fields of a REQ, RSP, DAT or SNP
// message, in the bit order the wire carries them. The link macros describe a
// *link* -- flits wrapped in the flow control that moves them, which for CHI is
// L-Credits and a LINKACTIVE handshake rather than valid/ready. RTL that sits
// behind a link layer wants the first; anything that touches the pins wants the
// second.
//
// Field order is the specification's, cross-read against XSCache's
// Message.scala, whose bundles pack with `Cat(getElements)` so that the
// last-declared field lands at the LSB. Written MSB first below, which means
// the *last* entry of each struct is bit 0.
//
// Widths come in as types rather than as parameters so that a link may differ
// from chi_pkg's reference configuration without redefining the encodings that
// go with it. `CHI_TYPEDEF_ALL` is the common case and takes the six that vary.

`ifndef CHI_TYPEDEF_SVH_
`define CHI_TYPEDEF_SVH_

////////////////////////////////////////////////////////////////////////////////////////////////////
// Channels
////////////////////////////////////////////////////////////////////////////////////////////////////

// REQ: requests from a Request Node towards a Home Node.
//
// Several fields share bits with others by request type, and only one of each group is named
// here: ReturnNID also carries StashNID, ReturnTxnID also carries SLCRepHint, StashNIDValid also
// carries Endian and Deep, LPID-with-padding also carries the group IDs, and Excl also carries
// SnoopMe. Which reading applies is decided by the opcode, not by the flit.
`define CHI_TYPEDEF_REQ_T(chi_req_t, qos_t, nodeid_t, txnid_t, size_t, addr_t, order_t, pcrd_type_t, mem_attr_t, lpid_t, tag_op_t, mpam_t, rsvdc_t) \
  typedef struct packed {                                                                          \
    /* MSB */                                                                                      \
    rsvdc_t                   rsvdc;                                                               \
    mpam_t                    mpam;                /* Issue E.b */                                 \
    logic                     trace_tag;                                                           \
    tag_op_t                  tag_op;              /* Issue E.b */                                 \
    logic                     exp_comp_ack;                                                        \
    logic                     excl;                /* snoop_me for Atomics */                      \
    lpid_t                    lp_id_with_padding;  /* {3'b0, LPID} or an 8-bit group ID */          \
    logic                     snp_attr;            /* do_dwt in Issue E.b */                       \
    mem_attr_t                mem_attr;                                                            \
    pcrd_type_t               p_crd_type;                                                          \
    order_t                   order;                                                               \
    logic                     allow_retry;                                                         \
    logic                     likely_shared;                                                       \
    logic                     ns;                                                                  \
    addr_t                    addr;                                                                \
    size_t                    size;                                                                \
    chi_pkg::chi_req_opcode_e opcode;                                                              \
    txnid_t                   return_txn_id;       /* slc_rep_hint in Issue E.b */                  \
    logic                     stash_nid_valid;     /* endian for Atomics, deep for CMOs */          \
    nodeid_t                  return_nid;          /* stash_nid for Stash */                       \
    txnid_t                   txn_id;                                                              \
    nodeid_t                  src_id;                                                              \
    nodeid_t                  tgt_id;                                                              \
    qos_t                     qos;                                                                 \
    /* LSB */                                                                                      \
  } chi_req_t;

// RSP: responses without data, in either direction.
`define CHI_TYPEDEF_RSP_T(chi_rsp_t, qos_t, nodeid_t, txnid_t, resp_err_t, resp_t, fwd_state_t, c_busy_t, pcrd_type_t, tag_op_t) \
  typedef struct packed {                                                                          \
    /* MSB */                                                                                      \
    logic                     trace_tag;                                                           \
    tag_op_t                  tag_op;      /* Issue E.b */                                         \
    pcrd_type_t               p_crd_type;                                                          \
    txnid_t                   db_id;                                                               \
    c_busy_t                  c_busy;      /* Issue E.b */                                         \
    fwd_state_t               fwd_state;   /* data_pull for Stash */                               \
    resp_t                    resp;                                                                \
    resp_err_t                resp_err;                                                            \
    chi_pkg::chi_rsp_opcode_e opcode;                                                              \
    txnid_t                   txn_id;                                                              \
    nodeid_t                  src_id;                                                              \
    nodeid_t                  tgt_id;                                                              \
    qos_t                     qos;                                                                 \
    /* LSB */                                                                                      \
  } chi_rsp_t;

// DAT: responses with data, in either direction.
//
// DataCheck and Poison are optional on a link. They are unconditional here because the link this
// package is configured for has them; a link without them passes zero-width types.
`define CHI_TYPEDEF_DAT_T(chi_dat_t, qos_t, nodeid_t, txnid_t, resp_err_t, resp_t, data_source_t, c_busy_t, cc_id_t, data_id_t, tag_op_t, tag_t, tu_t, rsvdc_t, be_t, data_t, data_check_t, poison_t) \
  typedef struct packed {                                                                          \
    /* MSB */                                                                                      \
    poison_t                  poison;       /* optional on a link */                               \
    data_check_t              data_check;   /* optional on a link */                               \
    data_t                    data;                                                                \
    be_t                      be;                                                                  \
    rsvdc_t                   rsvdc;                                                               \
    logic                     trace_tag;                                                           \
    tu_t                      tu;           /* Issue E.b */                                        \
    tag_t                     tag;          /* Issue E.b */                                        \
    tag_op_t                  tag_op;       /* Issue E.b */                                        \
    data_id_t                 data_id;                                                             \
    cc_id_t                   cc_id;                                                               \
    txnid_t                   db_id;                                                               \
    c_busy_t                  c_busy;       /* Issue E.b */                                        \
    data_source_t             data_source;  /* fwd_state / data_pull */                            \
    resp_t                    resp;                                                                \
    resp_err_t                resp_err;                                                            \
    chi_pkg::chi_dat_opcode_e opcode;                                                              \
    nodeid_t                  home_nid;                                                            \
    txnid_t                   txn_id;                                                              \
    nodeid_t                  src_id;                                                              \
    nodeid_t                  tgt_id;                                                              \
    qos_t                     qos;                                                                 \
    /* LSB */                                                                                      \
  } chi_dat_t;

// SNP: snoops from a Home Node towards a Request Node. There is no TgtID: a snoop is sent on the
// link to the node being snooped. `snp_addr_t` drops the three low bits of an address, because a
// snoop always names a cache line.
`define CHI_TYPEDEF_SNP_T(chi_snp_t, qos_t, nodeid_t, txnid_t, snp_addr_t, mpam_t)                 \
  typedef struct packed {                                                                          \
    /* MSB */                                                                                      \
    mpam_t                    mpam;             /* Issue E.b */                                    \
    logic                     trace_tag;                                                           \
    logic                     ret_to_src;                                                          \
    logic                     do_not_go_to_sd;  /* do_not_data_pull for Stash */                   \
    logic                     ns;                                                                  \
    snp_addr_t                addr;                                                                \
    chi_pkg::chi_snp_opcode_e opcode;                                                              \
    txnid_t                   fwd_txn_id;       /* stash_lpid / vmid_ext */                        \
    nodeid_t                  fwd_nid;                                                             \
    txnid_t                   txn_id;                                                              \
    nodeid_t                  src_id;                                                              \
    qos_t                     qos;                                                                 \
    /* LSB */                                                                                      \
  } chi_snp_t;

////////////////////////////////////////////////////////////////////////////////////////////////////
// The field types a link is built from
//
// `CHI_TYPEDEF_FIELDS` names the field types of one link: those the specification fixes, plus
// those derived from the address and data types passed in. `CHI_TYPEDEF_ALL` feeds them to the
// four channel macros, so one line declares `<name>_{req,rsp,dat,snp}_t` and everything they are
// built from.
////////////////////////////////////////////////////////////////////////////////////////////////////

`define CHI_TYPEDEF_FIELDS(__name, addr_t, data_t)                                                 \
  /* Fixed by the specification */                                                                 \
  typedef logic [chi_pkg::CHI_QOS_WIDTH-1:0]               __name``_qos_t;                         \
  typedef logic [chi_pkg::CHI_SIZE_WIDTH-1:0]              __name``_size_t;                        \
  typedef logic [chi_pkg::CHI_ORDER_WIDTH-1:0]             __name``_order_t;                       \
  typedef logic [chi_pkg::CHI_PCRDTYPE_WIDTH-1:0]          __name``_pcrd_type_t;                   \
  typedef logic [chi_pkg::CHI_LPID_WITH_PADDING_WIDTH-1:0] __name``_lpid_t;                        \
  typedef logic [chi_pkg::CHI_TAGOP_WIDTH-1:0]             __name``_tag_op_t;                      \
  typedef logic [chi_pkg::CHI_RESP_WIDTH-1:0]              __name``_resp_t;                        \
  typedef logic [chi_pkg::CHI_FWDSTATE_WIDTH-1:0]          __name``_fwd_state_t;                   \
  typedef logic [chi_pkg::CHI_CBUSY_WIDTH-1:0]             __name``_c_busy_t;                      \
  typedef logic [chi_pkg::CHI_DATASOURCE_WIDTH-1:0]        __name``_data_source_t;                 \
  typedef logic [chi_pkg::CHI_CCID_WIDTH-1:0]              __name``_cc_id_t;                       \
  typedef logic [chi_pkg::CHI_DATAID_WIDTH-1:0]            __name``_data_id_t;                     \
  /* Derived from this link's address and data width */                                            \
  typedef logic [($bits(addr_t)-3)-1:0]                    __name``_snp_addr_t;                    \
  typedef logic [$bits(data_t)/8-1:0]                      __name``_be_t;                          \
  typedef logic [$bits(data_t)/8-1:0]                      __name``_data_check_t;                  \
  typedef logic [$bits(data_t)/64-1:0]                     __name``_poison_t;                      \
  typedef logic [$bits(data_t)/32-1:0]                     __name``_tag_t;                         \
  typedef logic [$bits(data_t)/128-1:0]                    __name``_tu_t;

`define CHI_TYPEDEF_ALL(__name, nodeid_t, txnid_t, addr_t, data_t, req_rsvdc_t, dat_rsvdc_t)       \
  `CHI_TYPEDEF_FIELDS(__name, addr_t, data_t)                                                      \
  `CHI_TYPEDEF_REQ_T(__name``_req_t, __name``_qos_t, nodeid_t, txnid_t, __name``_size_t, addr_t,   \
      __name``_order_t, __name``_pcrd_type_t, chi_pkg::chi_mem_attr_t, __name``_lpid_t,            \
      __name``_tag_op_t, chi_pkg::chi_mpam_t, req_rsvdc_t)                                         \
  `CHI_TYPEDEF_RSP_T(__name``_rsp_t, __name``_qos_t, nodeid_t, txnid_t, chi_pkg::chi_resp_err_e,   \
      __name``_resp_t, __name``_fwd_state_t, __name``_c_busy_t, __name``_pcrd_type_t,              \
      __name``_tag_op_t)                                                                           \
  `CHI_TYPEDEF_DAT_T(__name``_dat_t, __name``_qos_t, nodeid_t, txnid_t, chi_pkg::chi_resp_err_e,   \
      __name``_resp_t, __name``_data_source_t, __name``_c_busy_t, __name``_cc_id_t,                \
      __name``_data_id_t, __name``_tag_op_t, __name``_tag_t, __name``_tu_t, dat_rsvdc_t,           \
      __name``_be_t, data_t, __name``_data_check_t, __name``_poison_t)                             \
  `CHI_TYPEDEF_SNP_T(__name``_snp_t, __name``_qos_t, nodeid_t, txnid_t, __name``_snp_addr_t,       \
      chi_pkg::chi_mpam_t)

////////////////////////////////////////////////////////////////////////////////////////////////////
// Links
//
// A CHI link is six channels and a handshake, and it is not valid/ready. The transmitter may send
// a flit only when it holds an L-Credit, and the receiver grants credits by pulsing LCRDV; there
// is no ready. So a link bundle groups, per direction, the flits that direction sends and the
// credits it gives back for the flits it receives.
//
// Named from the Request Node's point of view: an RN drives `chi_rn_link_tx_t` and receives
// `chi_rn_link_rx_t`, and a Home Node's ports are the same two types the other way round. Signal
// names match the specification's, so the mapping to a port list is by eye.
//
// FLITPEND is carried because the pins have it. It is an early indication that a flit may follow,
// intended for clock gating; nothing here needs to act on it.
////////////////////////////////////////////////////////////////////////////////////////////////////

`define CHI_TYPEDEF_CHAN_T(chi_chan_t, flit_t)                                                     \
  typedef struct packed {                                                                          \
    logic  flitpend;                                                                               \
    logic  flitv;                                                                                  \
    flit_t flit;                                                                                   \
  } chi_chan_t;

`define CHI_TYPEDEF_RN_LINK_TX_T(chi_rn_link_tx_t, chan_req_t, chan_rsp_t, chan_dat_t)             \
  typedef struct packed {                                                                          \
    /* Port and system coherency state */                                                          \
    logic      txsactive;                                                                          \
    logic      syscoreq;                                                                           \
    /* Link activation: the RN requests on TX and acknowledges on RX */                            \
    logic      tx_linkactivereq;                                                                   \
    logic      rx_linkactiveack;                                                                   \
    /* Flits the RN sends */                                                                       \
    chan_req_t txreq;                                                                              \
    chan_rsp_t txrsp;                                                                              \
    chan_dat_t txdat;                                                                              \
    /* Credits the RN grants for flits it receives */                                              \
    logic      rxrsp_lcrdv;                                                                        \
    logic      rxdat_lcrdv;                                                                        \
    logic      rxsnp_lcrdv;                                                                        \
  } chi_rn_link_tx_t;

`define CHI_TYPEDEF_RN_LINK_RX_T(chi_rn_link_rx_t, chan_rsp_t, chan_dat_t, chan_snp_t)             \
  typedef struct packed {                                                                          \
    logic      rxsactive;                                                                          \
    logic      syscoack;                                                                           \
    logic      rx_linkactivereq;                                                                   \
    logic      tx_linkactiveack;                                                                   \
    /* Flits the RN receives */                                                                    \
    chan_rsp_t rxrsp;                                                                              \
    chan_dat_t rxdat;                                                                              \
    chan_snp_t rxsnp;                                                                              \
    /* Credits granted for flits the RN sends */                                                   \
    logic      txreq_lcrdv;                                                                        \
    logic      txrsp_lcrdv;                                                                        \
    logic      txdat_lcrdv;                                                                        \
  } chi_rn_link_rx_t;

`define CHI_TYPEDEF_RN_LINK_ALL(__name, req_t, rsp_t, dat_t, snp_t)                                \
  `CHI_TYPEDEF_CHAN_T(__name``_chan_req_t, req_t)                                                  \
  `CHI_TYPEDEF_CHAN_T(__name``_chan_rsp_t, rsp_t)                                                  \
  `CHI_TYPEDEF_CHAN_T(__name``_chan_dat_t, dat_t)                                                  \
  `CHI_TYPEDEF_CHAN_T(__name``_chan_snp_t, snp_t)                                                  \
  `CHI_TYPEDEF_RN_LINK_TX_T(__name``_rn_link_tx_t, __name``_chan_req_t, __name``_chan_rsp_t,       \
      __name``_chan_dat_t)                                                                         \
  `CHI_TYPEDEF_RN_LINK_RX_T(__name``_rn_link_rx_t, __name``_chan_rsp_t, __name``_chan_dat_t,       \
      __name``_chan_snp_t)

`endif  // CHI_TYPEDEF_SVH_
