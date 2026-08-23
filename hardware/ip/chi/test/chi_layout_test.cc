// The package's flit structs against CHIron's bit layout.
//
// chi_layout_tb.sv sets every field of a flit to a value distinct from every
// other, reports each by name, and hands over the packed struct. This file
// decodes that vector with CHIron and checks that each field came out where the
// package put it. A field one bit out of place reads a neighbour's value, which
// is what the report below names.
//
// The two decoders exist for good reasons -- SystemVerilog for waveforms, RTL
// and assertions, C++ for the agents -- and this is the only thing that stops
// them drifting apart. See //hardware/ip/chi/README.md.

#include <cstdint>
#include <cstdio>
#include <map>
#include <string>
#include <vector>

#include "hardware/vip/chi/chi_flit.h"
#include "svdpi.h"

namespace {

enum Channel { kReq = 0, kRsp = 1, kDat = 2, kSnp = 3 };

const char* ChannelName(int channel) {
  switch (channel) {
    case kReq: return "REQ";
    case kRsp: return "RSP";
    case kDat: return "DAT";
    case kSnp: return "SNP";
    default: return "?";
  }
}

int failures = 0;
int checks = 0;

// What the package says it put in the flit it is about to hand over, by field
// name. Cleared after each flit is checked.
std::map<std::string, std::uint64_t> reported;

void Fail(const char* fmt, ...) __attribute__((format(printf, 1, 2)));
void Fail(const char* fmt, ...) {
  va_list args;
  va_start(args, fmt);
  std::printf("FAIL ");
  std::vprintf(fmt, args);
  std::printf("\n");
  va_end(args);
  ++failures;
}

// Compare one field of the decoded flit against what the package reported for
// it, and strike it off the list. Anything left over at the end is a field the
// package set and this file forgot to check, which is a hole rather than a
// pass.
void Check(int channel, const char* field, std::uint64_t decoded) {
  ++checks;
  const auto it = reported.find(field);
  if (it == reported.end()) {
    Fail("%s.%s: decoded 0x%llx, but the package reported no such field", ChannelName(channel),
         field, static_cast<unsigned long long>(decoded));
    return;
  }
  if (it->second != decoded)
    Fail("%s.%s: package set 0x%llx, CHIron decoded 0x%llx", ChannelName(channel), field,
         static_cast<unsigned long long>(it->second), static_cast<unsigned long long>(decoded));
  reported.erase(it);
}

void CheckNothingLeftOver(int channel) {
  for (const auto& [field, value] : reported) {
    Fail("%s.%s: the package set it to 0x%llx and this test never checked it", ChannelName(channel),
         field.c_str(), static_cast<unsigned long long>(value));
  }
  reported.clear();
}

template <typename T>
std::uint64_t Value(const T& field) {
  return static_cast<std::uint64_t>(field);
}

void CheckReq(const std::uint32_t* bits) {
  vip::chi::Req f{};
  if (!vip::chi::Unpack(f, bits)) {
    Fail("REQ: CHIron refused the flit");
    return;
  }
  Check(kReq, "qos", Value(f.QoS()));
  Check(kReq, "tgt_id", Value(f.TgtID()));
  Check(kReq, "src_id", Value(f.SrcID()));
  Check(kReq, "txn_id", Value(f.TxnID()));
  Check(kReq, "return_nid", Value(f.ReturnNID()));
  Check(kReq, "stash_nid_valid", Value(f.StashNIDValid()));
  Check(kReq, "return_txn_id", Value(f.ReturnTxnID()));
  Check(kReq, "opcode", Value(f.Opcode()));
  Check(kReq, "size", Value(f.Size()));
  Check(kReq, "addr", Value(f.Addr()));
  Check(kReq, "ns", Value(f.NS()));
  Check(kReq, "likely_shared", Value(f.LikelyShared()));
  Check(kReq, "allow_retry", Value(f.AllowRetry()));
  Check(kReq, "order", Value(f.Order()));
  Check(kReq, "p_crd_type", Value(f.PCrdType()));
  Check(kReq, "mem_attr", Value(f.MemAttr()));
  Check(kReq, "snp_attr", Value(f.SnpAttr()));
  // The eight bits the package calls lp_id_with_padding are TagGroupID here;
  // see the note in //hardware/vip/chi/chi_flit.h.
  Check(kReq, "lp_id_with_padding", Value(f.TagGroupID()));
  Check(kReq, "excl", Value(f.Excl()));
  Check(kReq, "exp_comp_ack", Value(f.ExpCompAck()));
  Check(kReq, "tag_op", Value(f.TagOp()));
  Check(kReq, "trace_tag", Value(f.TraceTag()));
  Check(kReq, "mpam", Value(f.MPAM()));
  Check(kReq, "rsvdc", Value(f.RSVDC()));
  CheckNothingLeftOver(kReq);
}

void CheckRsp(const std::uint32_t* bits) {
  vip::chi::Rsp f{};
  if (!vip::chi::Unpack(f, bits)) {
    Fail("RSP: CHIron refused the flit");
    return;
  }
  Check(kRsp, "qos", Value(f.QoS()));
  Check(kRsp, "tgt_id", Value(f.TgtID()));
  Check(kRsp, "src_id", Value(f.SrcID()));
  Check(kRsp, "txn_id", Value(f.TxnID()));
  Check(kRsp, "opcode", Value(f.Opcode()));
  Check(kRsp, "resp_err", Value(f.RespErr()));
  Check(kRsp, "resp", Value(f.Resp()));
  Check(kRsp, "fwd_state", Value(f.FwdState()));
  Check(kRsp, "c_busy", Value(f.CBusy()));
  Check(kRsp, "db_id", Value(f.DBID()));
  Check(kRsp, "p_crd_type", Value(f.PCrdType()));
  Check(kRsp, "tag_op", Value(f.TagOp()));
  Check(kRsp, "trace_tag", Value(f.TraceTag()));
  CheckNothingLeftOver(kRsp);
}

void CheckSnp(const std::uint32_t* bits) {
  vip::chi::Snp f{};
  if (!vip::chi::Unpack(f, bits)) {
    Fail("SNP: CHIron refused the flit");
    return;
  }
  Check(kSnp, "qos", Value(f.QoS()));
  Check(kSnp, "src_id", Value(f.SrcID()));
  Check(kSnp, "txn_id", Value(f.TxnID()));
  Check(kSnp, "fwd_nid", Value(f.FwdNID()));
  Check(kSnp, "fwd_txn_id", Value(f.FwdTxnID()));
  Check(kSnp, "opcode", Value(f.Opcode()));
  Check(kSnp, "addr", Value(f.Addr()));
  Check(kSnp, "ns", Value(f.NS()));
  Check(kSnp, "do_not_go_to_sd", Value(f.DoNotGoToSD()));
  Check(kSnp, "ret_to_src", Value(f.RetToSrc()));
  Check(kSnp, "trace_tag", Value(f.TraceTag()));
  Check(kSnp, "mpam", Value(f.MPAM()));
  CheckNothingLeftOver(kSnp);
}

void CheckDat(const std::uint32_t* bits) {
  vip::chi::Dat f{};
  if (!vip::chi::Unpack(f, bits)) {
    Fail("DAT: CHIron refused the flit");
    return;
  }
  Check(kDat, "qos", Value(f.QoS()));
  Check(kDat, "tgt_id", Value(f.TgtID()));
  Check(kDat, "src_id", Value(f.SrcID()));
  Check(kDat, "txn_id", Value(f.TxnID()));
  Check(kDat, "home_nid", Value(f.HomeNID()));
  Check(kDat, "opcode", Value(f.Opcode()));
  Check(kDat, "resp_err", Value(f.RespErr()));
  Check(kDat, "resp", Value(f.Resp()));
  Check(kDat, "data_source", Value(f.DataSource()));
  Check(kDat, "c_busy", Value(f.CBusy()));
  Check(kDat, "db_id", Value(f.DBID()));
  Check(kDat, "cc_id", Value(f.CCID()));
  Check(kDat, "data_id", Value(f.DataID()));
  Check(kDat, "tag_op", Value(f.TagOp()));
  Check(kDat, "tag", Value(f.Tag()));
  Check(kDat, "tu", Value(f.TU()));
  Check(kDat, "trace_tag", Value(f.TraceTag()));
  Check(kDat, "rsvdc", Value(f.RSVDC()));
  Check(kDat, "be", Value(f.BE()));
  Check(kDat, "data_check", Value(f.DataCheck()));
  Check(kDat, "poison", Value(f.Poison()));
  for (std::size_t i = 0; i < vip::chi::FlitConfig::dataWidth / 64; ++i) {
    char name[16];
    std::snprintf(name, sizeof(name), "data%zu", i);
    Check(kDat, name, f.Data()[i]);
  }
  CheckNothingLeftOver(kDat);
}

}  // namespace

extern "C" {

void chi_report_field(int channel, const char* field, long long value) {
  (void)channel;
  reported[field] = static_cast<std::uint64_t>(value);
}

void chi_check_flit(int channel, const svBitVecVal* flit) {
  switch (channel) {
    case kReq: CheckReq(flit); break;
    case kRsp: CheckRsp(flit); break;
    case kDat: CheckDat(flit); break;
    case kSnp: CheckSnp(flit); break;
    default: Fail("unknown channel %d", channel); break;
  }
}

}  // extern "C"

#include "Vchi_layout_tb.h"
#include "verilated.h"

// Verilator's legacy time hook; see chi_pkg_test.cc.
double sc_time_stamp() { return 0; }

int main(int argc, char** argv) {
  VerilatedContext context;
  context.commandArgs(argc, argv);
  Vchi_layout_tb tb{&context};

  tb.eval();
  tb.final();

  if (failures != 0) {
    std::printf("%d failures in %d fields\n", failures, checks);
    return 1;
  }
  std::printf("chi_pkg flit layout: %d fields agree with CHIron across four channels\n", checks);
  return 0;
}
