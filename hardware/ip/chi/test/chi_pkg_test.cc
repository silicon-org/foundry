// chi_pkg against CHIron, and against itself.
//
// The testbench reads the package and hands what it finds here through DPI;
// this file is the judge. See chi_pkg_tb.sv for what is checked and why. The
// interesting half is the opcode sweep: every encoding of each of the four
// opcode spaces, in both directions, so that an opcode this repository invented
// and one it forgot fail the same way.
//
// The two name spellings do not match character for character -- the package
// says CHI_REQ_READ_NOT_SHARED_DIRTY where CHIron says ReadNotSharedDirty --
// so both are reduced to lowercase letters and digits and the package's name
// must end with CHIron's. That absorbs the channel prefix, the underscores, and
// CHIron's AtomicStore::ADD, with no alias table.
//
// One exception, and it is a naming difference rather than a disagreement: the
// L-Credit return is RespLCrdReturn and DataLCrdReturn upstream where the
// package, which prefixes every RSP opcode with CHI_RSP_ and every DAT one with
// CHI_DAT_, calls them CHI_RSP_LCRD_RETURN and CHI_DAT_LCRD_RETURN. So a
// leading channel token is stripped from CHIron's name and the comparison
// retried -- only after the unmodified one has failed, so nothing else is
// loosened by it.

#include <algorithm>
#include <cctype>
#include <cstdint>
#include <cstdio>
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

void Fail(const std::string& message) {
  std::printf("FAIL %s\n", message.c_str());
  ++failures;
}

// Lowercase letters and digits only, so that CHI_REQ_READ_SHARED and
// ReadShared can be compared.
std::string Squash(const std::string& text) {
  std::string out;
  for (char c : text)
    if (std::isalnum(static_cast<unsigned char>(c)))
      out += static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
  return out;
}

bool EndsWith(const std::string& text, const std::string& suffix) {
  return text.size() >= suffix.size() &&
         text.compare(text.size() - suffix.size(), suffix.size(), suffix) == 0;
}

// How CHIron may spell the channel at the front of an opcode name.
const std::vector<std::string>& ChannelTokens(int channel) {
  static const std::vector<std::string> kReqTokens = {"req"};
  static const std::vector<std::string> kRspTokens = {"resp", "rsp"};
  static const std::vector<std::string> kDatTokens = {"data", "dat"};
  static const std::vector<std::string> kSnpTokens = {"snp"};
  static const std::vector<std::string> kNone = {};
  switch (channel) {
    case kReq: return kReqTokens;
    case kRsp: return kRspTokens;
    case kDat: return kDatTokens;
    case kSnp: return kSnpTokens;
    default: return kNone;
  }
}

bool NamesAgree(int channel, const std::string& ours, const std::string& theirs) {
  const std::string squashed_ours = Squash(ours);
  const std::string squashed_theirs = Squash(theirs);
  if (EndsWith(squashed_ours, squashed_theirs)) return true;

  for (const std::string& token : ChannelTokens(channel)) {
    if (squashed_theirs.rfind(token, 0) != 0) continue;
    if (EndsWith(squashed_ours, squashed_theirs.substr(token.size()))) return true;
  }
  return false;
}

// CHIron's view of one opcode space. Held as a decoder per channel because
// each is a different template instantiation.
CHI::Eb::REQOpcodeDecoder<vip::chi::Req> req_decoder;
CHI::Eb::RSPOpcodeDecoder<vip::chi::Rsp> rsp_decoder;
CHI::Eb::DATOpcodeDecoder<vip::chi::Dat> dat_decoder;
CHI::Eb::SNPOpcodeDecoder<vip::chi::Snp> snp_decoder;

// The name CHIron gives an encoding, or an empty string if it defines none.
std::string ChironOpcodeName(int channel, int opcode) {
  switch (channel) {
    case kReq: {
      const auto& info = req_decoder.Decode(opcode);
      return info.IsValid() ? info.GetName() : "";
    }
    case kRsp: {
      const auto& info = rsp_decoder.Decode(opcode);
      return info.IsValid() ? info.GetName() : "";
    }
    case kDat: {
      const auto& info = dat_decoder.Decode(opcode);
      return info.IsValid() ? info.GetName() : "";
    }
    case kSnp: {
      const auto& info = snp_decoder.Decode(opcode);
      return info.IsValid() ? info.GetName() : "";
    }
    default:
      return "";
  }
}

int ChironFlitWidth(int channel) {
  switch (channel) {
    case kReq: return vip::chi::Req::WIDTH;
    case kRsp: return vip::chi::Rsp::WIDTH;
    case kDat: return vip::chi::Dat::WIDTH;
    case kSnp: return vip::chi::Snp::WIDTH;
    default: return -1;
  }
}

}  // namespace

extern "C" {

void chi_expect(const char* what, long long got, long long want) {
  ++checks;
  if (got == want) return;
  char message[256];
  std::snprintf(message, sizeof(message), "%s: %lld, expected %lld", what, got, want);
  Fail(message);
}

void chi_expect_flit_width(int channel, int width) {
  ++checks;
  const int want = ChironFlitWidth(channel);
  if (width == want) return;
  char message[256];
  std::snprintf(message, sizeof(message),
                "%s flit: chi_pkg says %d bits, CHIron says %d",
                ChannelName(channel), width, want);
  Fail(message);
}

void chi_check_opcode(int channel, int opcode, const char* name) {
  ++checks;
  const std::string ours = name == nullptr ? "" : name;
  const std::string theirs = ChironOpcodeName(channel, opcode);

  if (ours.empty() && theirs.empty()) return;

  char message[256];
  if (ours.empty()) {
    std::snprintf(message, sizeof(message),
                  "%s 0x%02x: CHIron has %s, chi_pkg defines nothing",
                  ChannelName(channel), opcode, theirs.c_str());
    Fail(message);
    return;
  }
  if (theirs.empty()) {
    std::snprintf(message, sizeof(message),
                  "%s 0x%02x: chi_pkg has %s, CHIron defines nothing at that "
                  "encoding in Issue E.b",
                  ChannelName(channel), opcode, ours.c_str());
    Fail(message);
    return;
  }

  if (NamesAgree(channel, ours, theirs)) return;

  std::snprintf(message, sizeof(message), "%s 0x%02x: chi_pkg says %s, CHIron says %s",
                ChannelName(channel), opcode, ours.c_str(), theirs.c_str());
  Fail(message);
}

}  // extern "C"

#include "Vchi_pkg_tb.h"
#include "verilated.h"

// Verilator's legacy time hook, referenced by its runtime whenever SystemC is
// not in play. This testbench is one initial block, so time never advances and
// the value is never consulted -- it exists to satisfy the linker.
double sc_time_stamp() { return 0; }

int main(int argc, char** argv) {
  VerilatedContext context;
  context.commandArgs(argc, argv);
  Vchi_pkg_tb tb{&context};

  // The testbench is one initial block with no delays, so a single evaluation
  // runs all of it.
  tb.eval();
  tb.final();

  if (failures != 0) {
    std::printf("%d failures in %d checks\n", failures, checks);
    return 1;
  }
  std::printf("chi_pkg: %d checks against CHIron and against itself, all clean\n", checks);
  return 0;
}
