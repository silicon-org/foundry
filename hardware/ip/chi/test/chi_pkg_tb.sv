// chi_pkg against CHIron, and against itself.
//
// No clock and no design: the whole testbench is one initial block that reads
// the package and hands what it finds to C++. See chi_pkg_test.cc.

`include "chi_pkg_dpi.svh"

module chi_pkg_tb;

  import chi_pkg::*;

  // Every encoding of every opcode space, whether the package defines it or
  // not. `.name()` returns "" for a value that matches no enum member, so one
  // loop covers both directions of the comparison: an opcode CHIron knows and
  // the package does not shows up here as an empty name, and one the package
  // invented shows up as a name CHIron cannot decode.
  task automatic check_opcodes();
    chi_req_opcode_e req;
    chi_rsp_opcode_e rsp;
    chi_snp_opcode_e snp;
    chi_dat_opcode_e dat;

    for (int op = 0; op < (1 << CHI_REQ_OPCODE_WIDTH); op++) begin
      req = chi_req_opcode_e'(op);
      chi_check_opcode(`CHI_CH_REQ, op, req.name());
    end
    for (int op = 0; op < (1 << CHI_RSP_OPCODE_WIDTH); op++) begin
      rsp = chi_rsp_opcode_e'(op);
      chi_check_opcode(`CHI_CH_RSP, op, rsp.name());
    end
    for (int op = 0; op < (1 << CHI_SNP_OPCODE_WIDTH); op++) begin
      snp = chi_snp_opcode_e'(op);
      chi_check_opcode(`CHI_CH_SNP, op, snp.name());
    end
    for (int op = 0; op < (1 << CHI_DAT_OPCODE_WIDTH); op++) begin
      dat = chi_dat_opcode_e'(op);
      chi_check_opcode(`CHI_CH_DAT, op, dat.name());
    end
  endtask

  // The flit widths, which are what the whole package is for. These are the
  // numbers on //hardware/soc/xs_cluster's ports; the C++ side compares them
  // against CHIron's independently computed ones rather than against literals.
  task automatic check_widths();
    chi_expect_flit_width(`CHI_CH_REQ, $bits(chi_req_t));
    chi_expect_flit_width(`CHI_CH_RSP, $bits(chi_rsp_t));
    chi_expect_flit_width(`CHI_CH_DAT, $bits(chi_dat_t));
    chi_expect_flit_width(`CHI_CH_SNP, $bits(chi_snp_t));

    // And against the widths XSTop declares on its own ports, written out as
    // literals because that is what they are in the generated RTL. The
    // wrapper in //hardware/soc/xs_cluster connects a struct straight to those
    // vectors, so this is the check that stops a package one bit out from
    // connecting silently and decoding into nonsense. It is here rather than
    // in the wrapper because a generate block's $error is only a warning as
    // far as Verilator is concerned, and a warning is not a check.
    chi_expect("xstop_req_flit", $bits(chi_req_t), 162);
    chi_expect("xstop_rsp_flit", $bits(chi_rsp_t), 73);
    chi_expect("xstop_dat_flit", $bits(chi_dat_t), 422);
    chi_expect("xstop_snp_flit", $bits(chi_snp_t), 115);
  endtask

  // Field types against the parameters they were built from. A macro that
  // takes a width and a type has two places to get it wrong.
  task automatic check_field_widths();
    chi_expect("qos_width", $bits(chi_qos_t), CHI_QOS_WIDTH);
    chi_expect("size_width", $bits(chi_size_t), CHI_SIZE_WIDTH);
    chi_expect("order_width", $bits(chi_order_t), CHI_ORDER_WIDTH);
    chi_expect("pcrd_type_width", $bits(chi_pcrd_type_t), CHI_PCRDTYPE_WIDTH);
    chi_expect("lpid_width", $bits(chi_lpid_t), CHI_LPID_WITH_PADDING_WIDTH);
    chi_expect("tag_op_width", $bits(chi_tag_op_t), CHI_TAGOP_WIDTH);
    chi_expect("resp_width", $bits(chi_resp_t), CHI_RESP_WIDTH);
    chi_expect("fwd_state_width", $bits(chi_fwd_state_t), CHI_FWDSTATE_WIDTH);
    chi_expect("c_busy_width", $bits(chi_c_busy_t), CHI_CBUSY_WIDTH);
    chi_expect("data_source_width", $bits(chi_data_source_t), CHI_DATASOURCE_WIDTH);
    chi_expect("cc_id_width", $bits(chi_cc_id_t), CHI_CCID_WIDTH);
    chi_expect("data_id_width", $bits(chi_data_id_t), CHI_DATAID_WIDTH);
    chi_expect("snp_addr_width", $bits(chi_snp_addr_t), CHI_SNP_ADDR_WIDTH);
    chi_expect("be_width", $bits(chi_be_t), CHI_BE_WIDTH);
    chi_expect("data_check_width", $bits(chi_data_check_t), CHI_DATACHECK_WIDTH);
    chi_expect("poison_width", $bits(chi_poison_t), CHI_POISON_WIDTH);
    chi_expect("tag_width", $bits(chi_tag_t), CHI_TAG_WIDTH);
    chi_expect("tu_width", $bits(chi_tu_t), CHI_TAG_UPDATE_WIDTH);
    chi_expect("mem_attr_width", $bits(chi_mem_attr_t), CHI_MEMATTR_WIDTH);
    chi_expect("mpam_width", $bits(chi_mpam_t), CHI_MPAM_WIDTH);
    // A link bundle is its channels plus ten single-bit signals. Stating that
    // sum here is what catches a signal dropped from one direction.
    chi_expect("rn_link_tx_t",
               $bits(chi_rn_link_tx_t),
               4 + 3 * 2 + $bits(chi_req_t) + $bits(chi_rsp_t) + $bits(chi_dat_t) + 3);
    chi_expect("rn_link_rx_t",
               $bits(chi_rn_link_rx_t),
               4 + 3 * 2 + $bits(chi_rsp_t) + $bits(chi_dat_t) + $bits(chi_snp_t) + 3);
  endtask

  // The classifiers, over the whole five-bit snoop opcode space, against a
  // table written out longhand. Thirty-two values cost nothing to enumerate,
  // and enumerating them removes the argument about which cases were covered.
  task automatic check_snoop_classifiers();
    logic expected;
    for (int op = 0; op < 32; op++) begin
      expected = (op == CHI_SNP_UNIQUE_STASH) || (op == CHI_SNP_MAKE_INVALID_STASH);
      chi_expect($sformatf("is_snp_x_stash[%0d]", op), chi_is_snp_x_stash(op[4:0]), expected);

      expected = (op == CHI_SNP_STASH_UNIQUE) || (op == CHI_SNP_STASH_SHARED);
      chi_expect($sformatf("is_snp_stash_x[%0d]", op), chi_is_snp_stash_x(op[4:0]), expected);

      // The forwarding snoops are exactly 0x11 through 0x17, less the two
      // non-forwarding ones at 0x15 -- SnpPreferUnique -- and nothing else.
      expected = (op == CHI_SNP_SHARED_FWD) || (op == CHI_SNP_CLEAN_FWD) ||
                 (op == CHI_SNP_ONCE_FWD) || (op == CHI_SNP_NOT_SHARED_DIRTY_FWD) ||
                 (op == CHI_SNP_PREFER_UNIQUE_FWD) || (op == CHI_SNP_UNIQUE_FWD);
      chi_expect($sformatf("is_snp_x_fwd[%0d]", op), chi_is_snp_x_fwd(op[4:0]), expected);

      // Downgrade to Shared and invalidate are disjoint, and neither may claim
      // a stash-only or DVM opcode.
      expected = (op == CHI_SNP_CLEAN) || (op == CHI_SNP_CLEAN_FWD) ||
                 (op == CHI_SNP_SHARED) || (op == CHI_SNP_SHARED_FWD) ||
                 (op == CHI_SNP_NOT_SHARED_DIRTY) || (op == CHI_SNP_NOT_SHARED_DIRTY_FWD);
      chi_expect($sformatf("is_snp_to_b[%0d]", op), chi_is_snp_to_b(op[4:0]), expected);

      expected = (op == CHI_SNP_UNIQUE) || (op == CHI_SNP_UNIQUE_FWD) ||
                 (op == CHI_SNP_UNIQUE_STASH) || (op == CHI_SNP_CLEAN_INVALID) ||
                 (op == CHI_SNP_MAKE_INVALID) || (op == CHI_SNP_MAKE_INVALID_STASH);
      chi_expect($sformatf("is_snp_to_n[%0d]", op), chi_is_snp_to_n(op[4:0]), expected);

      chi_expect($sformatf("to_b_and_to_n_disjoint[%0d]", op),
                 chi_is_snp_to_b(op[4:0]) && chi_is_snp_to_n(op[4:0]), 0);
    end
  endtask

  // PassDirty is bit 2 of Resp and nothing else is.
  task automatic check_resp_helpers();
    for (int r = 0; r < 8; r++) begin
      chi_expect($sformatf("is_pass_dirty[%0d]", r), chi_is_pass_dirty(r[2:0]), (r >= 4));
      chi_expect($sformatf("set_pass_dirty[%0d]", r), chi_set_pass_dirty(r[2:0]), r | 3'b100);
      chi_expect($sformatf("clear_pass_dirty[%0d]", r), chi_set_pass_dirty(r[2:0], 1'b0), r);
    end
    // The two aliased states really are aliases, which is the only reason the
    // names are safe to use.
    chi_expect("ud_aliases_uc", CHI_RESP_UD, CHI_RESP_UC);
    chi_expect("uc_pd_aliases_ud_pd", CHI_RESP_UC_PD, CHI_RESP_UD_PD);
  endtask

  // The LINKACTIVE pair, both directions, all four combinations.
  task automatic check_link_state();
    chi_expect("link_state[0,0]", chi_link_state(1'b0, 1'b0), CHI_LINK_STOP);
    chi_expect("link_state[1,0]", chi_link_state(1'b1, 1'b0), CHI_LINK_ACTIVATE);
    chi_expect("link_state[1,1]", chi_link_state(1'b1, 1'b1), CHI_LINK_RUN);
    chi_expect("link_state[0,1]", chi_link_state(1'b0, 1'b1), CHI_LINK_DEACTIVATE);
  endtask

  // Every channel's L-Credit return is opcode zero, and no other opcode is.
  task automatic check_lcrd_return();
    for (int op = 0; op < 128; op++)
      chi_expect($sformatf("is_lcrd_return[%0d]", op), chi_is_lcrd_return(op[6:0]), (op == 0));
    chi_expect("req_lcrd_return", CHI_REQ_LCRD_RETURN, 0);
    chi_expect("rsp_lcrd_return", CHI_RSP_LCRD_RETURN, 0);
    chi_expect("snp_lcrd_return", CHI_SNP_LCRD_RETURN, 0);
    chi_expect("dat_lcrd_return", CHI_DAT_LCRD_RETURN, 0);
  endtask

  initial begin
    check_widths();
    check_field_widths();
    check_opcodes();
    check_snoop_classifiers();
    check_resp_helpers();
    check_link_state();
    check_lcrd_return();
  end

endmodule
