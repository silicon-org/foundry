// AMBA CHI, Issue E.b: field widths, encodings and opcodes.
//
// Three sources, and where they disagree the order of authority is this:
//
//   - ARM IHI 0050 for what a field means and what its encodings are. The
//     current issue is H; the values in the tables it shares with E.b have not
//     moved, and the fields H adds are absent below.
//   - CHIron's Issue-E.b headers for which opcodes exist in E.b, since H
//     defines a good many that do not. //hardware/ip/chi/test checks this
//     package against them for every encoding in each opcode space, so the
//     agreement is machine-checked rather than asserted here.
//   - XSCache's Message.scala for the bit order, because that is the RTL on
//     the other end of the link this package describes. Its bundles pack with
//     `Cat(getElements)`, which puts the last-declared field at the LSB, so
//     QoS is at bit 0 and the flit is built upwards.
//
// Issue E.b and not something newer because that is what
// //hardware/soc/xs_cluster speaks. The enum below exists so that the choice is
// visible in RTL that has to care, not because the other issues are supported.
`include "chi_typedef.svh"

package chi_pkg;

  ////////////////////////////////////////////////////////////////////////////////////////////////
  // CHI issue
  ////////////////////////////////////////////////////////////////////////////////////////////////

  typedef enum logic [1:0] {
    CHI_ISSUE_B  = 2'b00,
    CHI_ISSUE_C  = 2'b01,
    CHI_ISSUE_EB = 2'b10
  } chi_issue_e;

  ////////////////////////////////////////////////////////////////////////////////////////////////
  // Link configuration
  //
  // The widths a link is free to choose. These are the ones XiangShan's L2 emits, and they are
  // what `CHI_TYPEDEF_ALL` in chi_typedef.svh is given for the reference typedefs at the bottom of
  // this package. An IP with different widths invokes the macros with its own.
  ////////////////////////////////////////////////////////////////////////////////////////////////

  localparam int CHI_NODEID_WIDTH = 11;  // 7 to 16 permitted; 7 in Issue B/C
  localparam int CHI_TXNID_WIDTH = 12;  // 8 in Issue B/C
  localparam int CHI_ADDR_WIDTH = 48;  // 44 to 52 permitted
  localparam int CHI_DATA_WIDTH = 256;  // 128, 256 or 512 permitted
  localparam int CHI_REQ_RSVDC_WIDTH = 4;  // 0, or 4, 8, 12, 16, 24, 32
  localparam int CHI_DAT_RSVDC_WIDTH = 4;

  ////////////////////////////////////////////////////////////////////////////////////////////////
  // Field widths fixed by the specification
  ////////////////////////////////////////////////////////////////////////////////////////////////

  localparam int CHI_REQ_OPCODE_WIDTH = 7;
  localparam int CHI_RSP_OPCODE_WIDTH = 5;
  localparam int CHI_SNP_OPCODE_WIDTH = 5;
  localparam int CHI_DAT_OPCODE_WIDTH = 4;
  // Widest of the four, for logic that carries an opcode before the channel is known.
  localparam int CHI_OPCODE_WIDTH = CHI_REQ_OPCODE_WIDTH;

  localparam int CHI_QOS_WIDTH = 4;
  localparam int CHI_SIZE_WIDTH = 3;
  localparam int CHI_LPID_WIDTH = 5;
  // The REQ flit carries {3'b0, LPID[4:0]}, and a group CMO or a Memory Tagging request puts an
  // 8-bit group ID in the same place. The wire field is 8 bits either way.
  localparam int CHI_LPID_WITH_PADDING_WIDTH = 8;
  localparam int CHI_PCRDTYPE_WIDTH = 4;
  localparam int CHI_MEMATTR_WIDTH = 4;
  localparam int CHI_ORDER_WIDTH = 2;
  localparam int CHI_VMIDEXT_WIDTH = 8;
  localparam int CHI_RESPERR_WIDTH = 2;
  localparam int CHI_RESP_WIDTH = 3;
  localparam int CHI_FWDSTATE_WIDTH = 3;
  localparam int CHI_DATAPULL_WIDTH = 3;
  localparam int CHI_DATASOURCE_WIDTH = 4;
  localparam int CHI_CCID_WIDTH = 2;
  localparam int CHI_DATAID_WIDTH = 2;
  localparam int CHI_CBUSY_WIDTH = 3;  // Issue E.b
  localparam int CHI_MPAM_WIDTH = 11;  // Issue E.b; 12 or 15 from Issue F
  localparam int CHI_SLCREPHINT_WIDTH = 7;  // Issue E.b
  localparam int CHI_TAGOP_WIDTH = 2;  // Issue E.b

  ////////////////////////////////////////////////////////////////////////////////////////////////
  // Widths derived from the link configuration
  ////////////////////////////////////////////////////////////////////////////////////////////////

  localparam int CHI_TGTID_WIDTH = CHI_NODEID_WIDTH;
  localparam int CHI_SRCID_WIDTH = CHI_NODEID_WIDTH;
  localparam int CHI_RETURNNID_WIDTH = CHI_NODEID_WIDTH;
  localparam int CHI_STASHNID_WIDTH = CHI_NODEID_WIDTH;
  localparam int CHI_FWDNID_WIDTH = CHI_NODEID_WIDTH;
  localparam int CHI_HOMENID_WIDTH = CHI_NODEID_WIDTH;
  localparam int CHI_RETURNTXNID_WIDTH = CHI_TXNID_WIDTH;
  localparam int CHI_FWDTXNID_WIDTH = CHI_TXNID_WIDTH;
  localparam int CHI_DBID_WIDTH = CHI_TXNID_WIDTH;
  localparam int CHI_STASHLPID_WIDTH = CHI_LPID_WIDTH;
  // A snoop names a cache line, so its address field drops the three low bits.
  localparam int CHI_SNP_ADDR_WIDTH = CHI_ADDR_WIDTH - 3;
  localparam int CHI_BE_WIDTH = CHI_DATA_WIDTH / 8;
  localparam int CHI_DATACHECK_WIDTH = CHI_DATA_WIDTH / 8;
  localparam int CHI_POISON_WIDTH = CHI_DATA_WIDTH / 64;
  localparam int CHI_TAG_WIDTH = CHI_DATA_WIDTH / 32;  // Issue E.b memory tagging
  localparam int CHI_TAG_UPDATE_WIDTH = CHI_DATA_WIDTH / 128;  // Issue E.b memory tagging

  ////////////////////////////////////////////////////////////////////////////////////////////////
  // Field encodings
  ////////////////////////////////////////////////////////////////////////////////////////////////

  // Resp: for a snoop response, the final state of the snooped RN-F; for a completion, the final
  // state at the requester; for write data, the state of the data when it was sent. Bit 2 is
  // PassDirty -- "the responsibility of writing back the cache line is being passed on".
  typedef enum logic [CHI_RESP_WIDTH-1:0] {
    CHI_RESP_I     = 3'b000,  // Invalid
    CHI_RESP_SC    = 3'b001,  // Shared Clean
    CHI_RESP_UC    = 3'b010,  // Unique Clean, and Unique Dirty (see CHI_RESP_UD)
    CHI_RESP_SD    = 3'b011,  // Shared Dirty
    CHI_RESP_I_PD  = 3'b100,
    CHI_RESP_SC_PD = 3'b101,
    CHI_RESP_UD_PD = 3'b110,  // and UC_PD (see CHI_RESP_UC_PD)
    CHI_RESP_SD_PD = 3'b111
  } chi_resp_e;

  localparam logic [CHI_RESP_WIDTH-1:0] CHI_RESP_PASS_DIRTY = 3'b100;
  // UC and UD share an encoding and are told apart by PassDirty; likewise UC_PD and UD_PD. The
  // aliases exist so RTL can name the state it means.
  localparam chi_resp_e CHI_RESP_UD = CHI_RESP_UC;
  localparam chi_resp_e CHI_RESP_UC_PD = CHI_RESP_UD_PD;

  // RespErr
  typedef enum logic [CHI_RESPERR_WIDTH-1:0] {
    CHI_RESP_ERR_OK    = 2'b00,  // Normal okay, or an Exclusive access that failed
    CHI_RESP_ERR_EXOK  = 2'b01,  // Exclusive okay
    CHI_RESP_ERR_DERR  = 2'b10,  // Data error
    CHI_RESP_ERR_NDERR = 2'b11   // Non-data error
  } chi_resp_err_e;

  // Order: the ordering a requester asks for.
  typedef enum logic [CHI_ORDER_WIDTH-1:0] {
    CHI_ORDER_NONE             = 2'b00,
    CHI_ORDER_REQUEST_ACCEPTED = 2'b01,  // Reserved on an RN-to-HN link
    CHI_ORDER_REQUEST_ORDER    = 2'b10,  // Ordered Write Observation on an RN-to-HN link
    CHI_ORDER_ENDPOINT_ORDER   = 2'b11
  } chi_order_e;

  // MemAttr, four independent bits rather than an encoding.
  typedef struct packed {
    logic allocate;   // Allocation is recommended
    logic cacheable;  // A cache lookup is required
    logic device;     // Device rather than Normal memory
    logic ewa;        // Early Write Acknowledge permitted
  } chi_mem_attr_t;

  // MPAM, Issue E.b. Eleven bits; Issue F widens it to 12 or 15.
  typedef struct packed {
    logic [0:0] perf_mon_group;  // Performance Monitoring Group
    logic [8:0] part_id;         // Partition ID
    logic       mpam_ns;         // Non-secure
  } chi_mpam_t;

  ////////////////////////////////////////////////////////////////////////////////////////////////
  // REQ channel opcodes
  //
  // Opcode[6] selects between two halves of the encoding space, so the Issue-E.b additions sit at
  // 0x4x rather than following on from 0x3A.
  ////////////////////////////////////////////////////////////////////////////////////////////////

  typedef enum logic [CHI_REQ_OPCODE_WIDTH-1:0] {
    CHI_REQ_LCRD_RETURN                = 7'h00,
    CHI_REQ_READ_SHARED                = 7'h01,
    CHI_REQ_READ_CLEAN                 = 7'h02,
    CHI_REQ_READ_ONCE                  = 7'h03,
    CHI_REQ_READ_NO_SNP                = 7'h04,
    CHI_REQ_PCRD_RETURN                = 7'h05,
    CHI_REQ_READ_UNIQUE                = 7'h07,
    CHI_REQ_CLEAN_SHARED               = 7'h08,
    CHI_REQ_CLEAN_INVALID              = 7'h09,
    CHI_REQ_MAKE_INVALID               = 7'h0A,
    CHI_REQ_CLEAN_UNIQUE               = 7'h0B,
    CHI_REQ_MAKE_UNIQUE                = 7'h0C,
    CHI_REQ_EVICT                      = 7'h0D,
    CHI_REQ_READ_NO_SNP_SEP            = 7'h11,
    CHI_REQ_CLEAN_SHARED_PERSIST_SEP   = 7'h13,
    CHI_REQ_DVM_OP                     = 7'h14,
    CHI_REQ_WRITE_EVICT_FULL           = 7'h15,
    CHI_REQ_WRITE_CLEAN_FULL           = 7'h17,
    CHI_REQ_WRITE_UNIQUE_PTL           = 7'h18,
    CHI_REQ_WRITE_UNIQUE_FULL          = 7'h19,
    CHI_REQ_WRITE_BACK_PTL             = 7'h1A,
    CHI_REQ_WRITE_BACK_FULL            = 7'h1B,
    CHI_REQ_WRITE_NO_SNP_PTL           = 7'h1C,
    CHI_REQ_WRITE_NO_SNP_FULL          = 7'h1D,
    CHI_REQ_WRITE_UNIQUE_FULL_STASH    = 7'h20,
    CHI_REQ_WRITE_UNIQUE_PTL_STASH     = 7'h21,
    CHI_REQ_STASH_ONCE_SHARED          = 7'h22,
    CHI_REQ_STASH_ONCE_UNIQUE          = 7'h23,
    CHI_REQ_READ_ONCE_CLEAN_INVALID    = 7'h24,
    CHI_REQ_READ_ONCE_MAKE_INVALID     = 7'h25,
    CHI_REQ_READ_NOT_SHARED_DIRTY      = 7'h26,
    CHI_REQ_CLEAN_SHARED_PERSIST       = 7'h27,
    // AtomicStore and AtomicLoad are eight encodings each: Opcode[2:0] is the operation.
    CHI_REQ_ATOMIC_STORE_ADD           = 7'h28,
    CHI_REQ_ATOMIC_STORE_CLR           = 7'h29,
    CHI_REQ_ATOMIC_STORE_EOR           = 7'h2A,
    CHI_REQ_ATOMIC_STORE_SET           = 7'h2B,
    CHI_REQ_ATOMIC_STORE_SMAX          = 7'h2C,
    CHI_REQ_ATOMIC_STORE_SMIN          = 7'h2D,
    CHI_REQ_ATOMIC_STORE_UMAX          = 7'h2E,
    CHI_REQ_ATOMIC_STORE_UMIN          = 7'h2F,
    CHI_REQ_ATOMIC_LOAD_ADD            = 7'h30,
    CHI_REQ_ATOMIC_LOAD_CLR            = 7'h31,
    CHI_REQ_ATOMIC_LOAD_EOR            = 7'h32,
    CHI_REQ_ATOMIC_LOAD_SET            = 7'h33,
    CHI_REQ_ATOMIC_LOAD_SMAX           = 7'h34,
    CHI_REQ_ATOMIC_LOAD_SMIN           = 7'h35,
    CHI_REQ_ATOMIC_LOAD_UMAX           = 7'h36,
    CHI_REQ_ATOMIC_LOAD_UMIN           = 7'h37,
    CHI_REQ_ATOMIC_SWAP                = 7'h38,
    CHI_REQ_ATOMIC_COMPARE             = 7'h39,
    CHI_REQ_PREFETCH_TGT               = 7'h3A,
    // Opcode[6] set.
    CHI_REQ_MAKE_READ_UNIQUE           = 7'h41,
    CHI_REQ_WRITE_EVICT_OR_EVICT       = 7'h42,
    CHI_REQ_WRITE_UNIQUE_ZERO          = 7'h43,
    CHI_REQ_WRITE_NO_SNP_ZERO          = 7'h44,
    CHI_REQ_STASH_ONCE_SEP_SHARED      = 7'h47,
    CHI_REQ_STASH_ONCE_SEP_UNIQUE      = 7'h48,
    CHI_REQ_READ_PREFER_UNIQUE         = 7'h4C,
    // Combined write-and-CMO requests.
    CHI_REQ_WRITE_NO_SNP_FULL_CLEAN_SH            = 7'h50,
    CHI_REQ_WRITE_NO_SNP_FULL_CLEAN_INV           = 7'h51,
    CHI_REQ_WRITE_NO_SNP_FULL_CLEAN_SH_PER_SEP    = 7'h52,
    CHI_REQ_WRITE_UNIQUE_FULL_CLEAN_SH            = 7'h54,
    CHI_REQ_WRITE_UNIQUE_FULL_CLEAN_SH_PER_SEP    = 7'h56,
    CHI_REQ_WRITE_BACK_FULL_CLEAN_SH              = 7'h58,
    CHI_REQ_WRITE_BACK_FULL_CLEAN_INV             = 7'h59,
    CHI_REQ_WRITE_BACK_FULL_CLEAN_SH_PER_SEP      = 7'h5A,
    CHI_REQ_WRITE_CLEAN_FULL_CLEAN_SH             = 7'h5C,
    CHI_REQ_WRITE_CLEAN_FULL_CLEAN_SH_PER_SEP     = 7'h5E,
    CHI_REQ_WRITE_NO_SNP_PTL_CLEAN_SH             = 7'h60,
    CHI_REQ_WRITE_NO_SNP_PTL_CLEAN_INV            = 7'h61,
    CHI_REQ_WRITE_NO_SNP_PTL_CLEAN_SH_PER_SEP     = 7'h62,
    CHI_REQ_WRITE_UNIQUE_PTL_CLEAN_SH             = 7'h64,
    CHI_REQ_WRITE_UNIQUE_PTL_CLEAN_SH_PER_SEP     = 7'h66
  } chi_req_opcode_e;

  ////////////////////////////////////////////////////////////////////////////////////////////////
  // RSP channel opcodes
  ////////////////////////////////////////////////////////////////////////////////////////////////

  typedef enum logic [CHI_RSP_OPCODE_WIDTH-1:0] {
    CHI_RSP_LCRD_RETURN     = 5'h00,
    CHI_RSP_SNP_RESP        = 5'h01,
    CHI_RSP_COMP_ACK        = 5'h02,
    CHI_RSP_RETRY_ACK       = 5'h03,
    CHI_RSP_COMP            = 5'h04,
    CHI_RSP_COMP_DBID_RESP  = 5'h05,
    CHI_RSP_DBID_RESP       = 5'h06,
    CHI_RSP_PCRD_GRANT      = 5'h07,
    CHI_RSP_READ_RECEIPT    = 5'h08,
    CHI_RSP_SNP_RESP_FWDED  = 5'h09,
    CHI_RSP_TAG_MATCH       = 5'h0A,
    CHI_RSP_RESP_SEP_DATA   = 5'h0B,
    CHI_RSP_PERSIST         = 5'h0C,
    CHI_RSP_COMP_PERSIST    = 5'h0D,
    CHI_RSP_DBID_RESP_ORD   = 5'h0E,
    CHI_RSP_STASH_DONE      = 5'h10,
    CHI_RSP_COMP_STASH_DONE = 5'h11,
    CHI_RSP_COMP_CMO        = 5'h14
  } chi_rsp_opcode_e;

  ////////////////////////////////////////////////////////////////////////////////////////////////
  // SNP channel opcodes
  //
  // The channel prefix carries the specification's leading "Snp", so SnpUniqueFwd is
  // CHI_SNP_UNIQUE_FWD.
  ////////////////////////////////////////////////////////////////////////////////////////////////

  typedef enum logic [CHI_SNP_OPCODE_WIDTH-1:0] {
    CHI_SNP_LCRD_RETURN          = 5'h00,
    CHI_SNP_SHARED               = 5'h01,
    CHI_SNP_CLEAN                = 5'h02,
    CHI_SNP_ONCE                 = 5'h03,
    CHI_SNP_NOT_SHARED_DIRTY     = 5'h04,
    CHI_SNP_UNIQUE_STASH         = 5'h05,
    CHI_SNP_MAKE_INVALID_STASH   = 5'h06,
    CHI_SNP_UNIQUE               = 5'h07,
    CHI_SNP_CLEAN_SHARED         = 5'h08,
    CHI_SNP_CLEAN_INVALID        = 5'h09,
    CHI_SNP_MAKE_INVALID         = 5'h0A,
    CHI_SNP_STASH_UNIQUE         = 5'h0B,
    CHI_SNP_STASH_SHARED         = 5'h0C,
    CHI_SNP_DVM_OP               = 5'h0D,
    CHI_SNP_QUERY                = 5'h10,  // Issue E.b
    CHI_SNP_SHARED_FWD           = 5'h11,
    CHI_SNP_CLEAN_FWD            = 5'h12,
    CHI_SNP_ONCE_FWD             = 5'h13,
    CHI_SNP_NOT_SHARED_DIRTY_FWD = 5'h14,
    CHI_SNP_PREFER_UNIQUE        = 5'h15,  // Issue E.b
    CHI_SNP_PREFER_UNIQUE_FWD    = 5'h16,  // Issue E.b
    CHI_SNP_UNIQUE_FWD           = 5'h17
  } chi_snp_opcode_e;

  ////////////////////////////////////////////////////////////////////////////////////////////////
  // DAT channel opcodes
  //
  // Three names are abbreviated the way CHIron and XiangShan abbreviate them, because those are
  // what appear in every log and waveform this package will be read next to. In full, the
  // specification calls them CopyBackWriteData, NonCopyBackWriteData and
  // NonCopyBackWriteDataCompAck.
  ////////////////////////////////////////////////////////////////////////////////////////////////

  typedef enum logic [CHI_DAT_OPCODE_WIDTH-1:0] {
    CHI_DAT_LCRD_RETURN            = 4'h0,
    CHI_DAT_SNP_RESP_DATA          = 4'h1,
    CHI_DAT_COPY_BACK_WR_DATA      = 4'h2,
    CHI_DAT_NON_COPY_BACK_WR_DATA  = 4'h3,
    CHI_DAT_COMP_DATA              = 4'h4,
    CHI_DAT_SNP_RESP_DATA_PTL      = 4'h5,
    CHI_DAT_SNP_RESP_DATA_FWDED    = 4'h6,
    CHI_DAT_WRITE_DATA_CANCEL      = 4'h7,
    CHI_DAT_DATA_SEP_RESP          = 4'hB,
    CHI_DAT_NCB_WR_DATA_COMP_ACK   = 4'hC
  } chi_dat_opcode_e;

  ////////////////////////////////////////////////////////////////////////////////////////////////
  // Link layer
  //
  // The state of one direction of a link, from the LINKACTIVEREQ/LINKACTIVEACK pair. Both ends
  // derive it the same way, so it is here rather than in either of them.
  ////////////////////////////////////////////////////////////////////////////////////////////////

  typedef enum logic [1:0] {
    CHI_LINK_STOP       = 2'b00,  // req 0, ack 0
    CHI_LINK_ACTIVATE   = 2'b01,  // req 1, ack 0
    CHI_LINK_RUN        = 2'b10,  // req 1, ack 1
    CHI_LINK_DEACTIVATE = 2'b11   // req 0, ack 1
  } chi_link_state_e;

  function automatic chi_link_state_e chi_link_state(logic req, logic ack);
    case ({req, ack})
      2'b00:   return CHI_LINK_STOP;
      2'b10:   return CHI_LINK_ACTIVATE;
      2'b11:   return CHI_LINK_RUN;
      default: return CHI_LINK_DEACTIVATE;  // 2'b01
    endcase
  endfunction

  // The maximum number of L-Credits a receiver may hold outstanding on one channel.
  localparam int CHI_MAX_LCREDITS = 15;

  ////////////////////////////////////////////////////////////////////////////////////////////////
  // Helper functions
  ////////////////////////////////////////////////////////////////////////////////////////////////

  // Opcode 0 is the L-Credit return on every channel, and is not a transaction.
  function automatic logic chi_is_lcrd_return(logic [CHI_OPCODE_WIDTH-1:0] opcode);
    return opcode == '0;
  endfunction

  function automatic logic [CHI_RESP_WIDTH-1:0] chi_set_pass_dirty(logic [CHI_RESP_WIDTH-1:0] resp,
                                                                   logic pd = 1'b1);
    return resp | (pd ? CHI_RESP_PASS_DIRTY : '0);
  endfunction

  function automatic logic chi_is_pass_dirty(logic [CHI_RESP_WIDTH-1:0] resp);
    return |(resp & CHI_RESP_PASS_DIRTY);
  endfunction

  // Ordered at the completer: RequestOrder or EndpointOrder.
  function automatic logic chi_is_request_order(logic [CHI_ORDER_WIDTH-1:0] order);
    return order >= CHI_ORDER_REQUEST_ORDER;
  endfunction

  function automatic chi_mem_attr_t chi_default_mem_attr();
    chi_mem_attr_t attr;
    attr.allocate  = 1'b0;
    attr.cacheable = 1'b0;
    attr.device    = 1'b0;
    attr.ewa       = 1'b0;
    return attr;
  endfunction

  function automatic chi_mpam_t chi_default_mpam(logic mpam_ns = 1'b0);
    chi_mpam_t mpam;
    mpam.perf_mon_group = 1'b0;
    mpam.part_id        = 9'b0;
    mpam.mpam_ns        = mpam_ns;
    return mpam;
  endfunction

  ////////////////////////////////////////////////////////////////////////////////////////////////
  // Snoop opcode classifiers
  ////////////////////////////////////////////////////////////////////////////////////////////////

  // Snp*Stash: a snoop that also asks the target to stash the line.
  function automatic logic chi_is_snp_x_stash(logic [CHI_SNP_OPCODE_WIDTH-1:0] opcode);
    return (opcode == CHI_SNP_UNIQUE_STASH) || (opcode == CHI_SNP_MAKE_INVALID_STASH);
  endfunction

  // SnpStash*: a stash request with no coherence action.
  function automatic logic chi_is_snp_stash_x(logic [CHI_SNP_OPCODE_WIDTH-1:0] opcode);
    return (opcode == CHI_SNP_STASH_UNIQUE) || (opcode == CHI_SNP_STASH_SHARED);
  endfunction

  // Snp*Fwd: a snoop that asks the target to forward data to the original requester, which is
  // Direct Cache Transfer.
  function automatic logic chi_is_snp_x_fwd(logic [CHI_SNP_OPCODE_WIDTH-1:0] opcode);
    return (opcode == CHI_SNP_SHARED_FWD) ||
           (opcode == CHI_SNP_CLEAN_FWD) ||
           (opcode == CHI_SNP_ONCE_FWD) ||
           (opcode == CHI_SNP_NOT_SHARED_DIRTY_FWD) ||
           (opcode == CHI_SNP_PREFER_UNIQUE_FWD) ||
           (opcode == CHI_SNP_UNIQUE_FWD);
  endfunction

  function automatic logic chi_is_snp_once_x(logic [CHI_SNP_OPCODE_WIDTH-1:0] opcode);
    return (opcode == CHI_SNP_ONCE) || (opcode == CHI_SNP_ONCE_FWD);
  endfunction

  function automatic logic chi_is_snp_clean_x(logic [CHI_SNP_OPCODE_WIDTH-1:0] opcode);
    return (opcode == CHI_SNP_CLEAN) || (opcode == CHI_SNP_CLEAN_FWD);
  endfunction

  function automatic logic chi_is_snp_shared_x(logic [CHI_SNP_OPCODE_WIDTH-1:0] opcode);
    return (opcode == CHI_SNP_SHARED) || (opcode == CHI_SNP_SHARED_FWD);
  endfunction

  function automatic logic chi_is_snp_not_shared_dirty_x(logic [CHI_SNP_OPCODE_WIDTH-1:0] opcode);
    return (opcode == CHI_SNP_NOT_SHARED_DIRTY) || (opcode == CHI_SNP_NOT_SHARED_DIRTY_FWD);
  endfunction

  function automatic logic chi_is_snp_unique_x(logic [CHI_SNP_OPCODE_WIDTH-1:0] opcode);
    return (opcode == CHI_SNP_UNIQUE) ||
           (opcode == CHI_SNP_UNIQUE_FWD) ||
           (opcode == CHI_SNP_UNIQUE_STASH);
  endfunction

  function automatic logic chi_is_snp_make_invalid_x(logic [CHI_SNP_OPCODE_WIDTH-1:0] opcode);
    return (opcode == CHI_SNP_MAKE_INVALID) || (opcode == CHI_SNP_MAKE_INVALID_STASH);
  endfunction

  // A snoop that leaves the snoopee no worse than Shared -- TileLink's Branch.
  function automatic logic chi_is_snp_to_b(logic [CHI_SNP_OPCODE_WIDTH-1:0] opcode);
    return chi_is_snp_clean_x(opcode) ||
           chi_is_snp_shared_x(opcode) ||
           chi_is_snp_not_shared_dirty_x(opcode);
  endfunction

  // A snoop that invalidates the snoopee -- TileLink's None.
  function automatic logic chi_is_snp_to_n(logic [CHI_SNP_OPCODE_WIDTH-1:0] opcode);
    return chi_is_snp_unique_x(opcode) ||
           (opcode == CHI_SNP_CLEAN_INVALID) ||
           chi_is_snp_make_invalid_x(opcode);
  endfunction

  ////////////////////////////////////////////////////////////////////////////////////////////////
  // DAT opcode classifiers
  ////////////////////////////////////////////////////////////////////////////////////////////////

  function automatic logic chi_is_snp_resp_data_x(logic [CHI_DAT_OPCODE_WIDTH-1:0] opcode);
    return (opcode == CHI_DAT_SNP_RESP_DATA) ||
           (opcode == CHI_DAT_SNP_RESP_DATA_PTL) ||
           (opcode == CHI_DAT_SNP_RESP_DATA_FWDED);
  endfunction

  // Data written back by a requester that held the line: the HN owes it a CompDBIDResp first.
  function automatic logic chi_is_write_data(logic [CHI_DAT_OPCODE_WIDTH-1:0] opcode);
    return (opcode == CHI_DAT_COPY_BACK_WR_DATA) ||
           (opcode == CHI_DAT_NON_COPY_BACK_WR_DATA) ||
           (opcode == CHI_DAT_NCB_WR_DATA_COMP_ACK);
  endfunction

  ////////////////////////////////////////////////////////////////////////////////////////////////
  // Reference typedefs
  //
  // The four flit types and the two link bundles at the configuration declared at the top of this
  // package, which is XiangShan's. An IP with different widths includes chi_typedef.svh and
  // invokes the macros itself; this is here so that the common case is a type name rather than a
  // macro invocation in every file.
  ////////////////////////////////////////////////////////////////////////////////////////////////

  typedef logic [CHI_NODEID_WIDTH-1:0] chi_nodeid_t;
  typedef logic [CHI_TXNID_WIDTH-1:0] chi_txnid_t;
  typedef logic [CHI_ADDR_WIDTH-1:0] chi_addr_t;
  typedef logic [CHI_DATA_WIDTH-1:0] chi_data_t;
  typedef logic [CHI_REQ_RSVDC_WIDTH-1:0] chi_req_rsvdc_t;
  typedef logic [CHI_DAT_RSVDC_WIDTH-1:0] chi_dat_rsvdc_t;

  `CHI_TYPEDEF_ALL(chi, chi_nodeid_t, chi_txnid_t, chi_addr_t, chi_data_t, chi_req_rsvdc_t,
                   chi_dat_rsvdc_t)
  `CHI_TYPEDEF_RN_LINK_ALL(chi, chi_req_t, chi_rsp_t, chi_dat_t, chi_snp_t)

endpackage : chi_pkg
