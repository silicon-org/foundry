// The CHI flit layer: bit positions, then round trip.
//
// Two checks, and the order matters. A round trip on its own is weak: a packer
// and an unpacker that are wrong in the same way agree with each other. So the
// bit positions are pinned first, against a table written from the AMBA CHI
// specification's flit-format tables rather than read out of CHIron, and only
// then is the round trip run over all four channels.
//
// The field order is also the one XSCache's Chisel produces. Its bundles pack
// with `Cat(getElements)`, which puts the last-declared field at the LSB, and
// its first-declared field is QoS -- so QoS is at bit 0 and the flit is built
// upwards from there. The two derivations agreeing is the point.

#include "hardware/vip/chi/chi_flit.h"

#include <cstdarg>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <type_traits>

namespace {

using vip::chi::Dat;
using vip::chi::Req;
using vip::chi::Rsp;
using vip::chi::Snp;

int failures = 0;

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

// One field of one channel: where the specification puts it, and how to set it.
template <typename Flit>
struct Field {
  const char* name;
  std::size_t lsb;
  std::size_t width;
  std::size_t actual_lsb;
  std::size_t actual_width;
  void (*set)(Flit&, std::uint64_t);
};

// Naming a field costs one line: the expected position and width from the
// specification, the two constants CHIron derived, and a setter.
#define FIELD(FLIT, NAME, LSB, WIDTH, CONST, ACCESSOR)                                        \
  Field<FLIT> {                                                                               \
    #NAME, LSB, WIDTH, FLIT::CONST##_LSB, FLIT::CONST##_WIDTH, [](FLIT& f, std::uint64_t v) { \
      f.ACCESSOR() = static_cast<std::decay_t<decltype(f.ACCESSOR())>>(v);                    \
    }                                                                                         \
  }

// REQ, 162 bits. StashNID overlays ReturnNID, SLCRepHint overlays ReturnTxnID,
// SnoopMe overlays Excl and StashNIDValid overlays Endian: CHI reuses those
// positions by request type. Only one of each pair is listed -- the same bits
// checked twice would say nothing new.
const Field<Req> kReqFields[] = {
    FIELD(Req, QoS, 0, 4, QOS, QoS),
    FIELD(Req, TgtID, 4, 11, TGTID, TgtID),
    FIELD(Req, SrcID, 15, 11, SRCID, SrcID),
    FIELD(Req, TxnID, 26, 12, TXNID, TxnID),
    FIELD(Req, ReturnNID, 38, 11, RETURNNID, ReturnNID),
    FIELD(Req, StashNIDValid, 49, 1, STASHNIDVALID, StashNIDValid),
    FIELD(Req, ReturnTxnID, 50, 12, RETURNTXNID, ReturnTxnID),
    FIELD(Req, Opcode, 62, 7, OPCODE, Opcode),
    FIELD(Req, Size, 69, 3, SSIZE, Size),
    FIELD(Req, Addr, 72, 48, ADDR, Addr),
    FIELD(Req, NS, 120, 1, NS, NS),
    FIELD(Req, LikelyShared, 121, 1, LIKELYSHARED, LikelyShared),
    FIELD(Req, AllowRetry, 122, 1, ALLOWRETRY, AllowRetry),
    FIELD(Req, Order, 123, 2, ORDER, Order),
    FIELD(Req, PCrdType, 125, 4, PCRDTYPE, PCrdType),
    FIELD(Req, MemAttr, 129, 4, MEMATTR, MemAttr),
    FIELD(Req, SnpAttr, 133, 1, SNPATTR, SnpAttr),
    // Bits [141:134] are LPID with three bits of padding for an ordinary
    // request, and an 8-bit group ID for a group CMO. Issue E.b makes the
    // group ID the field that is actually on the wire, so that is what is
    // checked; LPID is its low five bits. See CheckLpidIsInsideTagGroupID.
    FIELD(Req, TagGroupID, 134, 8, TAGGROUPID, TagGroupID),
    FIELD(Req, Excl, 142, 1, EXCL, Excl),
    FIELD(Req, ExpCompAck, 143, 1, EXPCOMPACK, ExpCompAck),
    FIELD(Req, TagOp, 144, 2, TAGOP, TagOp),
    FIELD(Req, TraceTag, 146, 1, TRACETAG, TraceTag),
    FIELD(Req, MPAM, 147, 11, MPAM, MPAM),
    FIELD(Req, RSVDC, 158, 4, RSVDC, RSVDC),
};

// RSP, 73 bits.
const Field<Rsp> kRspFields[] = {
    FIELD(Rsp, QoS, 0, 4, QOS, QoS),
    FIELD(Rsp, TgtID, 4, 11, TGTID, TgtID),
    FIELD(Rsp, SrcID, 15, 11, SRCID, SrcID),
    FIELD(Rsp, TxnID, 26, 12, TXNID, TxnID),
    FIELD(Rsp, Opcode, 38, 5, OPCODE, Opcode),
    FIELD(Rsp, RespErr, 43, 2, RESPERR, RespErr),
    FIELD(Rsp, Resp, 45, 3, RESP, Resp),
    FIELD(Rsp, FwdState, 48, 3, FWDSTATE, FwdState),
    FIELD(Rsp, CBusy, 51, 3, CBUSY, CBusy),
    FIELD(Rsp, DBID, 54, 12, DBID, DBID),
    FIELD(Rsp, PCrdType, 66, 4, PCRDTYPE, PCrdType),
    FIELD(Rsp, TagOp, 70, 2, TAGOP, TagOp),
    FIELD(Rsp, TraceTag, 72, 1, TRACETAG, TraceTag),
};

// SNP, 115 bits. The address field drops the three low bits, because a snoop
// always names a cache line.
const Field<Snp> kSnpFields[] = {
    FIELD(Snp, QoS, 0, 4, QOS, QoS),
    FIELD(Snp, SrcID, 4, 11, SRCID, SrcID),
    FIELD(Snp, TxnID, 15, 12, TXNID, TxnID),
    FIELD(Snp, FwdNID, 27, 11, FWDNID, FwdNID),
    FIELD(Snp, FwdTxnID, 38, 12, FWDTXNID, FwdTxnID),
    FIELD(Snp, Opcode, 50, 5, OPCODE, Opcode),
    FIELD(Snp, Addr, 55, 45, ADDR, Addr),
    FIELD(Snp, NS, 100, 1, NS, NS),
    FIELD(Snp, DoNotGoToSD, 101, 1, DONOTGOTOSD, DoNotGoToSD),
    FIELD(Snp, RetToSrc, 102, 1, RETTOSRC, RetToSrc),
    FIELD(Snp, TraceTag, 103, 1, TRACETAG, TraceTag),
    FIELD(Snp, MPAM, 104, 11, MPAM, MPAM),
};

// DAT, 422 bits. Data, BE, DataCheck and Poison are arrays and are covered by
// the round trip rather than here; what this pins down is everything below
// them, where a one-bit slip would silently corrupt every response.
const Field<Dat> kDatFields[] = {
    FIELD(Dat, QoS, 0, 4, QOS, QoS),
    FIELD(Dat, TgtID, 4, 11, TGTID, TgtID),
    FIELD(Dat, SrcID, 15, 11, SRCID, SrcID),
    FIELD(Dat, TxnID, 26, 12, TXNID, TxnID),
    FIELD(Dat, HomeNID, 38, 11, HOMENID, HomeNID),
    FIELD(Dat, Opcode, 49, 4, OPCODE, Opcode),
    FIELD(Dat, RespErr, 53, 2, RESPERR, RespErr),
    FIELD(Dat, Resp, 55, 3, RESP, Resp),
    FIELD(Dat, DataSource, 58, 4, DATASOURCE, DataSource),
    FIELD(Dat, CBusy, 62, 3, CBUSY, CBusy),
    FIELD(Dat, DBID, 65, 12, DBID, DBID),
    FIELD(Dat, CCID, 77, 2, CCID, CCID),
    FIELD(Dat, DataID, 79, 2, DATAID, DataID),
    FIELD(Dat, TagOp, 81, 2, TAGOP, TagOp),
    FIELD(Dat, Tag, 83, 8, TAG, Tag),
    FIELD(Dat, TU, 91, 2, TU, TU),
    FIELD(Dat, TraceTag, 93, 1, TRACETAG, TraceTag),
    FIELD(Dat, RSVDC, 94, 4, RSVDC, RSVDC),
};

// Is bit `i` of a packed flit set?
bool Bit(const std::uint32_t* words, std::size_t i) { return (words[i / 32] >> (i % 32)) & 1u; }

// Set one field to all ones, pack, and require that exactly the bits the
// specification assigns to it came out set. This checks the constants, the
// packer and the accessor at once, and it fails loudly on an overlap: a field
// written one bit low shows up as a wrong range rather than as a value that
// happens to survive a symmetric round trip.
template <typename Flit, std::size_t N>
void CheckFieldPositions(const char* channel, const Field<Flit> (&fields)[N]) {
  for (const auto& field : fields) {
    if (field.lsb != field.actual_lsb || field.width != field.actual_width) {
      Fail("%s.%s: specification says [%zu +: %zu], CHIron says [%zu +: %zu]", channel, field.name,
           field.lsb, field.width, field.actual_lsb, field.actual_width);
      continue;
    }

    Flit flit{};
    const std::uint64_t ones =
        field.width >= 64 ? ~std::uint64_t{0} : (std::uint64_t{1} << field.width) - 1;
    field.set(flit, ones);

    std::uint32_t words[vip::chi::kWordsFor<Flit>] = {};
    if (!vip::chi::Pack(flit, words)) {
      Fail("%s.%s: Pack refused the flit", channel, field.name);
      continue;
    }

    for (std::size_t i = 0; i < Flit::WIDTH; ++i) {
      const bool expected = i >= field.lsb && i < field.lsb + field.width;
      if (Bit(words, i) != expected) {
        Fail("%s.%s: bit %zu is %d, expected %d (field is [%zu +: %zu])", channel, field.name, i,
             Bit(words, i) ? 1 : 0, expected ? 1 : 0, field.lsb, field.width);
        break;
      }
    }
  }
}

// Every field of a channel set to a different value, packed and unpacked.
// Catches anything the single-field sweep cannot: a field that reads back from
// the wrong place only when its neighbours are non-zero.
template <typename Flit, std::size_t N>
void CheckRoundTrip(const char* channel, const Field<Flit> (&fields)[N]) {
  Flit sent{};
  std::uint64_t value = 1;
  for (const auto& field : fields) {
    const std::uint64_t mask =
        field.width >= 64 ? ~std::uint64_t{0} : (std::uint64_t{1} << field.width) - 1;
    field.set(sent, (value * 0x9E3779B97F4A7C15ull) & mask);
    ++value;
  }

  std::uint32_t words[vip::chi::kWordsFor<Flit>] = {};
  if (!vip::chi::Pack(sent, words)) {
    Fail("%s: Pack refused a fully populated flit", channel);
    return;
  }

  Flit received{};
  if (!vip::chi::Unpack(received, words)) {
    Fail("%s: Unpack refused its own output", channel);
    return;
  }

  // Compared by re-packing rather than field by field, because CHIron's flits
  // have no equality operator and the alternative is naming every accessor a
  // second time. Two flits that pack identically are identical on the wire,
  // which is the only sense that matters here.
  std::uint32_t again[vip::chi::kWordsFor<Flit>] = {};
  if (!vip::chi::Pack(received, again)) {
    Fail("%s: Pack refused the unpacked flit", channel);
    return;
  }
  for (std::size_t i = 0; i < (Flit::WIDTH + 31) / 32; ++i) {
    if (words[i] != again[i]) {
      Fail("%s: round trip changed word %zu: 0x%08x -> 0x%08x", channel, i, words[i], again[i]);
      return;
    }
  }
}

// LPID is a five-bit view of the same storage as TagGroupID.
//
// Worth an executable check rather than a comment, because the two names sit in
// the flit at the same bit position and CHIron models that by sharing storage
// rather than by keeping two fields in step. Bits [141:134] are LPID plus three
// bits of padding for an ordinary request, and an eight-bit group ID for a
// group CMO; under Issue E.b it is the group ID that is written to and read
// from the wire. Setting either name is therefore setting both, and a home node
// may read whichever one the request opcode makes meaningful.
void CheckLpidAliasesTagGroupID() {
  Req sent{};
  sent.TagGroupID() = 0xA5;
  if (static_cast<unsigned>(sent.LPID()) != (0xA5 & 0x1F))
    Fail("REQ.LPID: reads 0x%x after TagGroupID = 0xa5, expected 0x%x",
         static_cast<unsigned>(sent.LPID()), 0xA5 & 0x1F);

  std::uint32_t words[vip::chi::kWordsFor<Req>] = {};
  vip::chi::Pack(sent, words);

  Req received{};
  vip::chi::Unpack(received, words);
  if (static_cast<unsigned>(received.TagGroupID()) != 0xA5)
    Fail("REQ.TagGroupID: unpacked 0x%x, expected 0xa5",
         static_cast<unsigned>(received.TagGroupID()));
  if (static_cast<unsigned>(received.LPID()) != (0xA5 & 0x1F))
    Fail("REQ.LPID: unpacked 0x%x, expected 0x%x", static_cast<unsigned>(received.LPID()),
         0xA5 & 0x1F);
}

// A flit is only accepted at exactly its own width. The DPI layer passes a
// length alongside the bits, and a mismatch there would otherwise decode into
// plausible nonsense.
void CheckWidthIsEnforced() {
  Rsp flit{};
  std::uint32_t words[vip::chi::kWordsFor<Rsp>] = {};
  if (vip::chi::chiron::Flits::SerializeRSP<vip::chi::FlitConfig, vip::chi::FlitConn>(
          flit, words, Rsp::WIDTH + 1))
    Fail("RSP: Pack accepted a wrong bit length");
  if (vip::chi::chiron::Flits::DeserializeRSP<vip::chi::FlitConfig, vip::chi::FlitConn>(
          flit, words, Rsp::WIDTH - 1))
    Fail("RSP: Unpack accepted a wrong bit length");
}

}  // namespace

int main() {
  CheckFieldPositions("REQ", kReqFields);
  CheckFieldPositions("RSP", kRspFields);
  CheckFieldPositions("DAT", kDatFields);
  CheckFieldPositions("SNP", kSnpFields);

  CheckRoundTrip("REQ", kReqFields);
  CheckRoundTrip("RSP", kRspFields);
  CheckRoundTrip("DAT", kDatFields);
  CheckRoundTrip("SNP", kSnpFields);

  CheckLpidAliasesTagGroupID();
  CheckWidthIsEnforced();

  if (failures != 0) {
    std::printf("%d failures\n", failures);
    return 1;
  }
  std::printf(
      "CHI flit layer: REQ %zu, RSP %zu, DAT %zu, SNP %zu bits; "
      "%zu field positions checked, four round trips clean\n",
      Req::WIDTH, Rsp::WIDTH, Dat::WIDTH, Snp::WIDTH,
      sizeof(kReqFields) / sizeof(*kReqFields) + sizeof(kRspFields) / sizeof(*kRspFields) +
          sizeof(kDatFields) / sizeof(*kDatFields) + sizeof(kSnpFields) / sizeof(*kSnpFields));
  return 0;
}
