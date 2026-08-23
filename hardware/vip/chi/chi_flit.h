// The CHI link configuration this repository speaks, and the proof it matches
// the DUT.
//
// Everything else under //hardware/vip/chi is written against these aliases
// rather than against CHIron directly, so that the four numbers below are
// stated once. They are not free parameters: they are what XiangShan's L2
// emits, and the static_asserts are what makes a disagreement a compile error
// in this file rather than a decode that silently produces nonsense two
// milestones later.

#ifndef HARDWARE_VIP_CHI_CHI_FLIT_H_
#define HARDWARE_VIP_CHI_CHI_FLIT_H_

#include <cstddef>
#include <cstdint>

#include "chi_eb/spec/chi_eb_protocol.hpp"
#include "chi_eb/util/chi_eb_util_decoding.hpp"
#include "chi_eb/util/chi_eb_util_flit.hpp"

namespace vip::chi {

// CHIron describes three issues of the specification from one source tree, and
// the Issue-E.b view of it lives in CHI::Eb. Never include the chi/ headers
// underneath directly; see chiron/PROVENANCE.md.
namespace chiron = CHI::Eb;

// The link XiangShan's XSNoCTop presents.
//
//   NodeID       11  the width io_nodeID is declared at in the generated top
//   ReqAddr      48
//   ReqRSVDC      4
//   DatRSVDC      4
//   Data        256  so a 64-byte line is two DAT beats, DataID 0 and 2
//   DataCheck   yes  } together these are the 36 bits that take a DAT flit
//   Poison      yes  } from 386 to 422
//   MPAM        yes
//
// XSCache derives the same numbers from `Eb_CONFIG` in
// xscache/chi/Message.scala; the assertions below are the two agreeing.
using FlitConfig = chiron::FlitConfiguration<11, 48, 4, 4, 256, true, true, true>;

// CHIron's flit templates take a second parameter saying which levels of the
// bundle are held by pointer for zero-copy. Nothing here shares storage with a
// simulator, so every level is by value, which is what the default means.
using FlitConn = CHI::Connection<>;

using Req = chiron::Flits::REQ<FlitConfig, FlitConn>;
using Rsp = chiron::Flits::RSP<FlitConfig, FlitConn>;
using Dat = chiron::Flits::DAT<FlitConfig, FlitConn>;
using Snp = chiron::Flits::SNP<FlitConfig, FlitConn>;

// The widths on //hardware/soc/xs_cluster's CHI port. If one of these fails,
// every later assumption about the link is wrong and nothing below is worth
// debugging.
static_assert(Req::WIDTH == 162, "REQ flit width disagrees with xs_cluster");
static_assert(Rsp::WIDTH == 73, "RSP flit width disagrees with xs_cluster");
static_assert(Dat::WIDTH == 422, "DAT flit width disagrees with xs_cluster");
static_assert(Snp::WIDTH == 115, "SNP flit width disagrees with xs_cluster");

// Words of storage a flit needs, which is one more than it occupies.
//
// The extra word is not padding. CHIron's flit writer initialises the word a
// field spills into, and a field ending exactly on a word boundary spills into
// a word past the end of the flit. Verilator and DPI both hand us
// ceil(WIDTH/32) words, so buffers we own are sized with this and buffers we
// are given are copied into one before being written.
template <typename Flit>
inline constexpr std::size_t kWordsFor = (Flit::WIDTH + 31) / 32 + 1;

// Bits as a simulator presents them: 32-bit words, least significant first.
// This is Verilator's VlWide and DPI's svBitVecVal, which are the same thing.
using FlitWords = std::uint32_t*;
using ConstFlitWords = const std::uint32_t*;

// Decoding. CHIron takes a non-const pointer only because its reader was
// declared that way; the reader walks the buffer and never writes to it, so
// casting away const at this one boundary is sound and is done here rather
// than at each of the dozen call sites.
//
// One field of a decoded REQ does not mean what its name suggests: LPID is a
// five-bit view of the same storage as TagGroupID, because CHI puts a logical
// processor ID and a group ID at the same eight bits and tells them apart by
// request opcode. test/chi_flit_test.cc pins that down.
inline bool Unpack(Req& flit, ConstFlitWords bits) {
  return chiron::Flits::DeserializeREQ<FlitConfig, FlitConn>(flit, const_cast<FlitWords>(bits),
                                                             Req::WIDTH);
}
inline bool Unpack(Rsp& flit, ConstFlitWords bits) {
  return chiron::Flits::DeserializeRSP<FlitConfig, FlitConn>(flit, const_cast<FlitWords>(bits),
                                                             Rsp::WIDTH);
}
inline bool Unpack(Dat& flit, ConstFlitWords bits) {
  return chiron::Flits::DeserializeDAT<FlitConfig, FlitConn>(flit, const_cast<FlitWords>(bits),
                                                             Dat::WIDTH);
}
inline bool Unpack(Snp& flit, ConstFlitWords bits) {
  return chiron::Flits::DeserializeSNP<FlitConfig, FlitConn>(flit, const_cast<FlitWords>(bits),
                                                             Snp::WIDTH);
}

// Encoding. The caller's buffer must be kWordsFor<Flit> long; see above.
inline bool Pack(const Req& flit, FlitWords bits) {
  return chiron::Flits::SerializeREQ<FlitConfig, FlitConn>(flit, bits, Req::WIDTH);
}
inline bool Pack(const Rsp& flit, FlitWords bits) {
  return chiron::Flits::SerializeRSP<FlitConfig, FlitConn>(flit, bits, Rsp::WIDTH);
}
inline bool Pack(const Dat& flit, FlitWords bits) {
  return chiron::Flits::SerializeDAT<FlitConfig, FlitConn>(flit, bits, Dat::WIDTH);
}
inline bool Pack(const Snp& flit, FlitWords bits) {
  return chiron::Flits::SerializeSNP<FlitConfig, FlitConn>(flit, bits, Snp::WIDTH);
}

}  // namespace vip::chi

#endif  // HARDWARE_VIP_CHI_CHI_FLIT_H_
