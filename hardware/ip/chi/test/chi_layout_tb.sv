// The package's flit structs against CHIron's bit layout.
//
// Each field is set to a value distinct from every other, reported by name, and
// then the whole struct is handed over as a packed vector for C++ to decode
// with CHIron. If the two disagree about where a field sits, one of them reads
// a neighbour's value and the comparison says which field and what it found.
//
// Only this direction is needed. CHIron's own bit positions are pinned against
// a table written from the specification in
// //hardware/vip/chi/test:chi_flit_test, so agreeing with CHIron here is
// agreeing with the specification.

`include "chi_layout_dpi.svh"

module chi_layout_tb;

  import chi_pkg::*;

  // Distinct per field, and wide enough that a one-bit slip changes the value
  // rather than hiding in a run of zeros. Truncation to the field width is the
  // caller's; the reported value is truncated the same way.
  function automatic longint unsigned pattern(int unsigned index);
    return (64'(index) + 64'd1) * 64'h9E3779B97F4A7C15;
  endfunction

  // Set a field and report what was set, truncated to the field's width.
  `define SET(__channel, __flit, __field, __index, __width)                                        \
    __flit.__field = type(__flit.__field)'((__width)'(pattern(__index)));                                                 \
    chi_report_field(__channel, `"__field`", longint'({{(64 - __width){1'b0}}, __flit.__field}));

  task automatic check_req();
    chi_req_t f = '0;
    `SET(`CHI_CH_REQ, f, qos, 0, $bits(f.qos))
    `SET(`CHI_CH_REQ, f, tgt_id, 1, $bits(f.tgt_id))
    `SET(`CHI_CH_REQ, f, src_id, 2, $bits(f.src_id))
    `SET(`CHI_CH_REQ, f, txn_id, 3, $bits(f.txn_id))
    `SET(`CHI_CH_REQ, f, return_nid, 4, $bits(f.return_nid))
    `SET(`CHI_CH_REQ, f, stash_nid_valid, 5, $bits(f.stash_nid_valid))
    `SET(`CHI_CH_REQ, f, return_txn_id, 6, $bits(f.return_txn_id))
    `SET(`CHI_CH_REQ, f, opcode, 7, $bits(f.opcode))
    `SET(`CHI_CH_REQ, f, size, 8, $bits(f.size))
    `SET(`CHI_CH_REQ, f, addr, 9, $bits(f.addr))
    `SET(`CHI_CH_REQ, f, ns, 10, $bits(f.ns))
    `SET(`CHI_CH_REQ, f, likely_shared, 11, $bits(f.likely_shared))
    `SET(`CHI_CH_REQ, f, allow_retry, 12, $bits(f.allow_retry))
    `SET(`CHI_CH_REQ, f, order, 13, $bits(f.order))
    `SET(`CHI_CH_REQ, f, p_crd_type, 14, $bits(f.p_crd_type))
    `SET(`CHI_CH_REQ, f, mem_attr, 15, $bits(f.mem_attr))
    `SET(`CHI_CH_REQ, f, snp_attr, 16, $bits(f.snp_attr))
    `SET(`CHI_CH_REQ, f, lp_id_with_padding, 17, $bits(f.lp_id_with_padding))
    `SET(`CHI_CH_REQ, f, excl, 18, $bits(f.excl))
    `SET(`CHI_CH_REQ, f, exp_comp_ack, 19, $bits(f.exp_comp_ack))
    `SET(`CHI_CH_REQ, f, tag_op, 20, $bits(f.tag_op))
    `SET(`CHI_CH_REQ, f, trace_tag, 21, $bits(f.trace_tag))
    `SET(`CHI_CH_REQ, f, mpam, 22, $bits(f.mpam))
    `SET(`CHI_CH_REQ, f, rsvdc, 23, $bits(f.rsvdc))
    chi_check_flit(`CHI_CH_REQ, {{(512 - $bits(chi_req_t)){1'b0}}, f});
  endtask

  task automatic check_rsp();
    chi_rsp_t f = '0;
    `SET(`CHI_CH_RSP, f, qos, 0, $bits(f.qos))
    `SET(`CHI_CH_RSP, f, tgt_id, 1, $bits(f.tgt_id))
    `SET(`CHI_CH_RSP, f, src_id, 2, $bits(f.src_id))
    `SET(`CHI_CH_RSP, f, txn_id, 3, $bits(f.txn_id))
    `SET(`CHI_CH_RSP, f, opcode, 4, $bits(f.opcode))
    `SET(`CHI_CH_RSP, f, resp_err, 5, $bits(f.resp_err))
    `SET(`CHI_CH_RSP, f, resp, 6, $bits(f.resp))
    `SET(`CHI_CH_RSP, f, fwd_state, 7, $bits(f.fwd_state))
    `SET(`CHI_CH_RSP, f, c_busy, 8, $bits(f.c_busy))
    `SET(`CHI_CH_RSP, f, db_id, 9, $bits(f.db_id))
    `SET(`CHI_CH_RSP, f, p_crd_type, 10, $bits(f.p_crd_type))
    `SET(`CHI_CH_RSP, f, tag_op, 11, $bits(f.tag_op))
    `SET(`CHI_CH_RSP, f, trace_tag, 12, $bits(f.trace_tag))
    chi_check_flit(`CHI_CH_RSP, {{(512 - $bits(chi_rsp_t)){1'b0}}, f});
  endtask

  task automatic check_snp();
    chi_snp_t f = '0;
    `SET(`CHI_CH_SNP, f, qos, 0, $bits(f.qos))
    `SET(`CHI_CH_SNP, f, src_id, 1, $bits(f.src_id))
    `SET(`CHI_CH_SNP, f, txn_id, 2, $bits(f.txn_id))
    `SET(`CHI_CH_SNP, f, fwd_nid, 3, $bits(f.fwd_nid))
    `SET(`CHI_CH_SNP, f, fwd_txn_id, 4, $bits(f.fwd_txn_id))
    `SET(`CHI_CH_SNP, f, opcode, 5, $bits(f.opcode))
    `SET(`CHI_CH_SNP, f, addr, 6, $bits(f.addr))
    `SET(`CHI_CH_SNP, f, ns, 7, $bits(f.ns))
    `SET(`CHI_CH_SNP, f, do_not_go_to_sd, 8, $bits(f.do_not_go_to_sd))
    `SET(`CHI_CH_SNP, f, ret_to_src, 9, $bits(f.ret_to_src))
    `SET(`CHI_CH_SNP, f, trace_tag, 10, $bits(f.trace_tag))
    `SET(`CHI_CH_SNP, f, mpam, 11, $bits(f.mpam))
    chi_check_flit(`CHI_CH_SNP, {{(512 - $bits(chi_snp_t)){1'b0}}, f});
  endtask

  // The data-bearing fields are wider than the 64 bits a report carries, so
  // data, be, data_check and poison are reported in 64-bit slices. Their
  // placement is what a wrong DAT layout gets wrong first, because everything
  // below them shifts.
  task automatic check_dat();
    chi_dat_t f = '0;
    `SET(`CHI_CH_DAT, f, qos, 0, $bits(f.qos))
    `SET(`CHI_CH_DAT, f, tgt_id, 1, $bits(f.tgt_id))
    `SET(`CHI_CH_DAT, f, src_id, 2, $bits(f.src_id))
    `SET(`CHI_CH_DAT, f, txn_id, 3, $bits(f.txn_id))
    `SET(`CHI_CH_DAT, f, home_nid, 4, $bits(f.home_nid))
    `SET(`CHI_CH_DAT, f, opcode, 5, $bits(f.opcode))
    `SET(`CHI_CH_DAT, f, resp_err, 6, $bits(f.resp_err))
    `SET(`CHI_CH_DAT, f, resp, 7, $bits(f.resp))
    `SET(`CHI_CH_DAT, f, data_source, 8, $bits(f.data_source))
    `SET(`CHI_CH_DAT, f, c_busy, 9, $bits(f.c_busy))
    `SET(`CHI_CH_DAT, f, db_id, 10, $bits(f.db_id))
    `SET(`CHI_CH_DAT, f, cc_id, 11, $bits(f.cc_id))
    `SET(`CHI_CH_DAT, f, data_id, 12, $bits(f.data_id))
    `SET(`CHI_CH_DAT, f, tag_op, 13, $bits(f.tag_op))
    `SET(`CHI_CH_DAT, f, tag, 14, $bits(f.tag))
    `SET(`CHI_CH_DAT, f, tu, 15, $bits(f.tu))
    `SET(`CHI_CH_DAT, f, trace_tag, 16, $bits(f.trace_tag))
    `SET(`CHI_CH_DAT, f, rsvdc, 17, $bits(f.rsvdc))
    `SET(`CHI_CH_DAT, f, be, 18, $bits(f.be))
    `SET(`CHI_CH_DAT, f, data_check, 19, $bits(f.data_check))
    `SET(`CHI_CH_DAT, f, poison, 20, $bits(f.poison))
    for (int unsigned i = 0; i < $bits(f.data) / 64; i++) begin
      f.data[i*64 +: 64] = pattern(32 + i);
      chi_report_field(`CHI_CH_DAT, $sformatf("data%0d", i), longint'(f.data[i*64 +: 64]));
    end
    chi_check_flit(`CHI_CH_DAT, {{(512 - $bits(chi_dat_t)){1'b0}}, f});
  endtask

  initial begin
    check_req();
    check_rsp();
    check_dat();
    check_snp();
  end

endmodule
