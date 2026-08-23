// The CHI home node, with no RTL in the build.
//
// The node is a function from flits to flits, so this is a table of requests
// and the responses each must produce. It builds in a second and runs in
// milliseconds, which is the point: a bug in what a CompDBIDResp carries should
// be found here and not in a simulation of 1868 generated modules where it
// arrives as a core that stopped fetching.
//
// One case per opcode the node claims to support, plus the bookkeeping that is
// easy to get subtly wrong and impossible to see afterwards -- which identifier
// echoes where, and what a write's byte enables actually reach.

#include "hardware/vip/chi/chi_home_node.h"

#include <cstdint>
#include <cstdio>
#include <span>
#include <string>
#include <vector>

#include "hardware/vip/common/memory.h"

namespace {

namespace ReqOp = vip::chi::chiron::Opcodes::REQ;
namespace RspOp = vip::chi::chiron::Opcodes::RSP;
namespace DatOp = vip::chi::chiron::Opcodes::DAT;
namespace Resps = vip::chi::chiron::Resps;
namespace RespErrs = vip::chi::chiron::RespErrs;

using vip::chi::Dat;
using vip::chi::HomeNode;
using vip::chi::Req;
using vip::chi::Rsp;
using vip::chi::Snp;

constexpr std::uint32_t kHomeId = 0x2A;
constexpr std::uint32_t kRequesterId = 0x15;
constexpr std::uint64_t kBase = 0x8000'0000;
constexpr unsigned kLineBytes = 64;
constexpr unsigned kBeatBytes = vip::chi::FlitConfig::dataWidth / 8;

int failures = 0;

void Fail(const std::string& what) {
  std::printf("FAIL %s\n", what.c_str());
  ++failures;
}

void ExpectEq(const std::string& what, std::uint64_t got, std::uint64_t want) {
  if (got == want) return;
  Fail(what);
  std::printf("  got %#llx, expected %#llx\n", static_cast<unsigned long long>(got),
              static_cast<unsigned long long>(want));
}

// CHI encodes a size as its base-2 logarithm, which is worth naming rather than
// writing 6 and hoping the reader remembers what it meant.
constexpr unsigned SizeOf(unsigned bytes) {
  unsigned encoded = 0;
  while ((1u << encoded) < bytes) ++encoded;
  return encoded;
}

Req MakeReq(unsigned opcode, std::uint64_t address, unsigned bytes, std::uint32_t txn_id,
            bool expects_comp_ack = false) {
  Req flit{};
  flit.SrcID() = static_cast<Req::srcid_t>(kRequesterId);
  flit.TgtID() = static_cast<Req::tgtid_t>(kHomeId);
  flit.TxnID() = static_cast<Req::txnid_t>(txn_id);
  flit.Opcode() = static_cast<Req::opcode_t>(opcode);
  flit.Addr() = static_cast<Req::addr_t>(address);
  flit.Size() = static_cast<Req::ssize_t>(SizeOf(bytes));
  flit.ExpCompAck() = expects_comp_ack ? 1 : 0;
  return flit;
}

Dat MakeWriteData(unsigned opcode, std::uint32_t dbid, unsigned data_id, std::uint64_t fill,
                  std::uint64_t byte_enables) {
  Dat flit{};
  flit.SrcID() = static_cast<Dat::srcid_t>(kRequesterId);
  flit.TgtID() = static_cast<Dat::tgtid_t>(kHomeId);
  flit.TxnID() = static_cast<Dat::txnid_t>(dbid);
  flit.Opcode() = static_cast<Dat::opcode_t>(opcode);
  flit.DataID() = static_cast<Dat::dataid_t>(data_id);
  flit.BE() = static_cast<Dat::be_t>(byte_enables);
  for (unsigned word = 0; word < kBeatBytes / 8; ++word) flit.Data()[word] = fill + word;
  return flit;
}

// Drains everything the node wants to send, so a case can look at it as a list.
struct Sent {
  std::vector<Rsp> rsp;
  std::vector<Dat> dat;
  std::vector<Snp> snp;
};

Sent Drain(HomeNode& node) {
  Sent sent;
  Rsp rsp{};
  while (node.NextTxRsp(&rsp)) sent.rsp.push_back(rsp);
  Dat dat{};
  while (node.NextTxDat(&dat)) sent.dat.push_back(dat);
  Snp snp{};
  while (node.NextTxSnp(&snp)) sent.snp.push_back(snp);
  return sent;
}

// Fills memory with a value derived from the address, so that a beat delivered
// from the wrong place is visible in its contents rather than only in a count.
void FillPattern(vip::SparseMemory& memory, std::uint64_t address, std::size_t bytes) {
  std::vector<std::uint8_t> pattern(bytes);
  for (std::size_t i = 0; i < bytes; ++i)
    pattern[i] = static_cast<std::uint8_t>((address + i) * 7 + 1);
  memory.Write(address, pattern);
}

std::uint64_t BeatWord(const Dat& flit, unsigned word) { return flit.Data()[word]; }

// The eight bytes of memory at `address`, as one little-endian word.
std::uint64_t MemoryWord(vip::SparseMemory& memory, std::uint64_t address) {
  std::vector<std::uint8_t> bytes(8);
  memory.Read(address, bytes);
  std::uint64_t value = 0;
  for (unsigned i = 0; i < 8; ++i) value |= static_cast<std::uint64_t>(bytes[i]) << (i * 8);
  return value;
}

struct Fixture {
  vip::SparseMemory memory;
  HomeNode node{HomeNode::Config{kHomeId, "chi.hn.test", kLineBytes}, memory};
};

////////////////////////////////////////////////////////////////////////////////////////////////
// Reads
////////////////////////////////////////////////////////////////////////////////////////////////

// A full line at this data width is two beats, and which half each carries is
// DataID -- 0 and 2, counting 128-bit chunks, not 0 and 1.
void FullLineReadIsTwoBeats() {
  Fixture f;
  FillPattern(f.memory, kBase, kLineBytes);

  f.node.NextReq(MakeReq(ReqOp::ReadNoSnp, kBase, kLineBytes, 0x111));
  const Sent sent = Drain(f.node);

  if (sent.dat.size() != 2) {
    Fail("full-line read");
    std::printf("  %zu data beats, expected 2\n", sent.dat.size());
    return;
  }
  ExpectEq("full-line read: no response flit", sent.rsp.size(), 0);
  ExpectEq("full-line read: DataID of the first beat", sent.dat[0].DataID(), 0);
  ExpectEq("full-line read: DataID of the second beat", sent.dat[1].DataID(), 2);
  ExpectEq("full-line read: opcode", sent.dat[0].Opcode(), DatOp::CompData);
  ExpectEq("full-line read: first word", BeatWord(sent.dat[0], 0), MemoryWord(f.memory, kBase));
  ExpectEq("full-line read: second beat's first word", BeatWord(sent.dat[1], 0),
           MemoryWord(f.memory, kBase + kBeatBytes));
}

// Everything the requester needs to answer: its own transaction identifier back,
// where to send the CompAck, and under which identifier.
void ReadEchoesIdentifiers() {
  Fixture f;
  f.node.NextReq(MakeReq(ReqOp::ReadNotSharedDirty, kBase, kLineBytes, 0x321, true));
  const Sent sent = Drain(f.node);
  if (sent.dat.empty()) {
    Fail("read identifiers: no data at all");
    return;
  }
  ExpectEq("read: TgtID is the requester", sent.dat[0].TgtID(), kRequesterId);
  ExpectEq("read: SrcID is this node", sent.dat[0].SrcID(), kHomeId);
  ExpectEq("read: TxnID is the requester's", sent.dat[0].TxnID(), 0x321);
  ExpectEq("read: HomeNID is this node", sent.dat[0].HomeNID(), kHomeId);
  ExpectEq("read: RespErr", sent.dat[0].RespErr(), RespErrs::OK);
}

// Pins the bug that cost a day: DataCheck left at zero reads as even parity, so
// CoupledL2 marked every line corrupt. The symptom was a hardware-error
// exception in a 1868-module simulation; the cause is checkable in milliseconds.
void CompDataCarriesOddByteParity() {
  Fixture f;
  f.node.NextReq(MakeReq(ReqOp::ReadNotSharedDirty, kBase, kLineBytes, 0x777, false));
  const Sent sent = Drain(f.node);
  if (sent.dat.size() != 2) {
    Fail("DataCheck: expected two beats");
    return;
  }

  for (unsigned beat = 0; beat < sent.dat.size(); ++beat) {
    const Dat& flit = sent.dat[beat];
    std::uint64_t want = 0;
    for (unsigned i = 0; i < kBeatBytes; ++i) {
      const auto byte = static_cast<std::uint8_t>(flit.Data()[i / 8] >> ((i % 8) * 8));
      // Odd parity over {byte, bit}.
      if (__builtin_parity(byte) == 0) want |= std::uint64_t{1} << i;
    }
    ExpectEq("DataCheck: odd parity over beat " + std::to_string(beat),
             static_cast<std::uint64_t>(flit.DataCheck()), want);
    // And nothing claims the bytes were already corrupt upstream.
    ExpectEq("Poison: clear on beat " + std::to_string(beat),
             static_cast<std::uint64_t>(flit.Poison()), 0);
  }
}

// A read the requester may cache gets UC; one it may not gets I. Handing UC to a
// ReadOnce would invite the requester to keep a line it is not allowed to.
void ReadRespDependsOnTheOpcode() {
  {
    Fixture f;
    f.node.NextReq(MakeReq(ReqOp::ReadNotSharedDirty, kBase, kLineBytes, 1));
    const Sent sent = Drain(f.node);
    if (sent.dat.empty()) return Fail("cacheable read produced no data");
    ExpectEq("ReadNotSharedDirty: Resp", sent.dat[0].Resp(), Resps::UC);
  }
  {
    Fixture f;
    f.node.NextReq(MakeReq(ReqOp::ReadOnce, kBase, kLineBytes, 2));
    const Sent sent = Drain(f.node);
    if (sent.dat.empty()) return Fail("ReadOnce produced no data");
    ExpectEq("ReadOnce: Resp", sent.dat[0].Resp(), Resps::I);
  }
  {
    Fixture f;
    f.node.NextReq(MakeReq(ReqOp::ReadNoSnp, kBase, 8, 3));
    const Sent sent = Drain(f.node);
    if (sent.dat.empty()) return Fail("ReadNoSnp produced no data");
    ExpectEq("ReadNoSnp: Resp", sent.dat[0].Resp(), Resps::I);
  }
}

// An eight-byte read is one beat carrying the aligned region it falls inside,
// and the DataID has to say which region that was. This is the MMIO path.
void SubBeatReadIsOneBeatWithTheRightDataId() {
  Fixture f;
  FillPattern(f.memory, kBase, kLineBytes);

  const std::uint64_t address = kBase + 0x24;  // inside the second beat
  f.node.NextReq(MakeReq(ReqOp::ReadNoSnp, address, 8, 0x77));
  const Sent sent = Drain(f.node);

  if (sent.dat.size() != 1) {
    Fail("sub-beat read");
    std::printf("  %zu data beats, expected 1\n", sent.dat.size());
    return;
  }
  ExpectEq("sub-beat read: DataID", sent.dat[0].DataID(), 2);
  ExpectEq("sub-beat read: contents", BeatWord(sent.dat[0], 0),
           MemoryWord(f.memory, kBase + kBeatBytes));
}

// A read that asked for a CompAck is not finished until one arrives, and the
// identifier it arrives under is the DBID the data carried.
void CompAckRetiresTheTransaction() {
  Fixture f;
  f.node.NextReq(MakeReq(ReqOp::ReadUnique, kBase, kLineBytes, 0x55, true));
  const Sent sent = Drain(f.node);
  if (sent.dat.empty()) return Fail("read with ExpCompAck produced no data");

  ExpectEq("ExpCompAck: outstanding before", f.node.Outstanding(), 1);

  Rsp ack{};
  ack.SrcID() = static_cast<Rsp::srcid_t>(kRequesterId);
  ack.Opcode() = static_cast<Rsp::opcode_t>(RspOp::CompAck);
  ack.TxnID() = sent.dat[0].DBID();
  f.node.NextRsp(ack);

  ExpectEq("ExpCompAck: outstanding after", f.node.Outstanding(), 0);
  ExpectEq("ExpCompAck: counted", f.node.stats().comp_acks, 1);
  ExpectEq("ExpCompAck: nothing unsupported", f.node.stats().unsupported, 0);
}

// A read that did not ask for one leaves nothing behind.
void ReadWithoutCompAckRetiresImmediately() {
  Fixture f;
  f.node.NextReq(MakeReq(ReqOp::ReadNoSnp, kBase, kLineBytes, 0x66));
  Drain(f.node);
  ExpectEq("read without CompAck: outstanding", f.node.Outstanding(), 0);
}

////////////////////////////////////////////////////////////////////////////////////////////////
// Writes
////////////////////////////////////////////////////////////////////////////////////////////////

// CompDBIDResp first, then the data under the identifier it named. Sending the
// data under the requester's own transaction identifier is the mistake this
// checks against.
void WriteBackFullLandsInMemory() {
  Fixture f;
  f.node.NextReq(MakeReq(ReqOp::WriteBackFull, kBase, kLineBytes, 0x201));
  const Sent response = Drain(f.node);

  if (response.rsp.size() != 1) {
    Fail("WriteBackFull");
    std::printf("  %zu response flits, expected 1\n", response.rsp.size());
    return;
  }
  ExpectEq("WriteBackFull: opcode", response.rsp[0].Opcode(), RspOp::CompDBIDResp);
  ExpectEq("WriteBackFull: Resp", response.rsp[0].Resp(), Resps::I);
  ExpectEq("WriteBackFull: TxnID is the requester's", response.rsp[0].TxnID(), 0x201);
  ExpectEq("WriteBackFull: no data yet", response.dat.size(), 0);

  const std::uint32_t dbid = static_cast<std::uint32_t>(response.rsp[0].DBID());
  const std::uint64_t all = ~std::uint64_t{0};

  f.node.NextDat(MakeWriteData(DatOp::CopyBackWrData, dbid, 0, 0xAAAA'0000, all));
  ExpectEq("WriteBackFull: still outstanding after one beat", f.node.Outstanding(), 1);

  f.node.NextDat(MakeWriteData(DatOp::CopyBackWrData, dbid, 2, 0xBBBB'0000, all));
  ExpectEq("WriteBackFull: retired after two beats", f.node.Outstanding(), 0);

  ExpectEq("WriteBackFull: first beat in memory", MemoryWord(f.memory, kBase), 0xAAAA'0000);
  ExpectEq("WriteBackFull: second beat in memory", MemoryWord(f.memory, kBase + kBeatBytes),
           0xBBBB'0000);
  ExpectEq("WriteBackFull: beats counted", f.node.stats().write_beats, 2);
}

// Byte enables are how a partial write reaches memory, and a store to a
// single word inside a line is the whole of the tohost path.
void PartialWriteHonoursByteEnables() {
  Fixture f;
  FillPattern(f.memory, kBase, kLineBytes);
  const std::uint64_t before = MemoryWord(f.memory, kBase + 8);

  f.node.NextReq(MakeReq(ReqOp::WriteNoSnpPtl, kBase, 8, 0x301));
  const Sent response = Drain(f.node);
  if (response.rsp.size() != 1) return Fail("partial write produced no CompDBIDResp");

  const std::uint32_t dbid = static_cast<std::uint32_t>(response.rsp[0].DBID());
  // The low eight bytes only.
  f.node.NextDat(MakeWriteData(DatOp::NonCopyBackWrData, dbid, 0, 0xCAFE'0000, 0xFF));

  ExpectEq("partial write: the enabled bytes", MemoryWord(f.memory, kBase), 0xCAFE'0000);
  ExpectEq("partial write: the bytes beyond them", MemoryWord(f.memory, kBase + 8), before);
  ExpectEq("partial write: retired", f.node.Outstanding(), 0);
}

// The requester may decide the line was clean after all. The transaction ends
// and no byte moves.
void WriteDataCancelWritesNothing() {
  Fixture f;
  FillPattern(f.memory, kBase, kLineBytes);
  const std::uint64_t before = MemoryWord(f.memory, kBase);

  f.node.NextReq(MakeReq(ReqOp::WriteBackFull, kBase, kLineBytes, 0x401));
  const Sent response = Drain(f.node);
  if (response.rsp.size() != 1) return Fail("WriteDataCancel setup produced no CompDBIDResp");

  Dat cancel{};
  cancel.Opcode() = static_cast<Dat::opcode_t>(DatOp::WriteDataCancel);
  cancel.TxnID() = response.rsp[0].DBID();
  f.node.NextDat(cancel);

  ExpectEq("WriteDataCancel: memory untouched", MemoryWord(f.memory, kBase), before);
  ExpectEq("WriteDataCancel: retired", f.node.Outstanding(), 0);
}

////////////////////////////////////////////////////////////////////////////////////////////////
// Dataless
////////////////////////////////////////////////////////////////////////////////////////////////

// Each of these is a statement about a cache, and the only thing that differs is
// the state the requester is left in.
void DatalessRequestsGetComp() {
  struct Case {
    const char* name;
    unsigned opcode;
    unsigned resp;
  };
  const Case cases[] = {
      {"Evict", ReqOp::Evict, Resps::I},
      {"CleanUnique", ReqOp::CleanUnique, Resps::UC},
      {"MakeUnique", ReqOp::MakeUnique, Resps::UC},
      {"CleanShared", ReqOp::CleanShared, Resps::I},
      {"CleanInvalid", ReqOp::CleanInvalid, Resps::I},
      {"MakeInvalid", ReqOp::MakeInvalid, Resps::I},
  };

  for (const Case& one : cases) {
    Fixture f;
    f.node.NextReq(MakeReq(one.opcode, kBase, kLineBytes, 0x501));
    const Sent sent = Drain(f.node);

    if (sent.rsp.size() != 1) {
      Fail(std::string(one.name) + ": response count");
      std::printf("  %zu response flits, expected 1\n", sent.rsp.size());
      continue;
    }
    ExpectEq(std::string(one.name) + ": opcode", sent.rsp[0].Opcode(), RspOp::Comp);
    ExpectEq(std::string(one.name) + ": Resp", sent.rsp[0].Resp(), one.resp);
    ExpectEq(std::string(one.name) + ": no data", sent.dat.size(), 0);
    ExpectEq(std::string(one.name) + ": retired", f.node.Outstanding(), 0);
  }
}

////////////////////////////////////////////////////////////////////////////////////////////////
// Things that should not happen
////////////////////////////////////////////////////////////////////////////////////////////////

// A request this node does not implement is answered with an error and counted.
// Ignoring it would stall the requester, and the failure would surface as a
// timeout in whatever was running at the time.
void UnsupportedRequestIsAnsweredAndCounted() {
  Fixture f;
  f.node.NextReq(MakeReq(ReqOp::AtomicSwap, kBase, 8, 0x601));
  const Sent sent = Drain(f.node);

  ExpectEq("unsupported: counted", f.node.stats().unsupported, 1);
  if (sent.rsp.size() != 1) {
    Fail("unsupported: response count");
    return;
  }
  ExpectEq("unsupported: RespErr", sent.rsp[0].RespErr(), RespErrs::NDERR);
  ExpectEq("unsupported: TxnID is the requester's", sent.rsp[0].TxnID(), 0x601);
}

// A CompAck for a transaction that was never opened means the two ends have
// diverged, and the node should say so rather than quietly forget it.
void StrayCompAckIsCounted() {
  Fixture f;
  Rsp ack{};
  ack.Opcode() = static_cast<Rsp::opcode_t>(RspOp::CompAck);
  ack.TxnID() = static_cast<Rsp::txnid_t>(0xABC);
  f.node.NextRsp(ack);
  ExpectEq("stray CompAck: counted", f.node.stats().unsupported, 1);
}

// Write data under an identifier nobody handed out, likewise.
void StrayWriteDataIsCounted() {
  Fixture f;
  f.node.NextDat(MakeWriteData(DatOp::CopyBackWrData, 0xDEF, 0, 0, ~std::uint64_t{0}));
  ExpectEq("stray write data: counted", f.node.stats().unsupported, 1);
}

// Nothing else holds a copy of any line on this link, so there is never
// anything to snoop. If that ever changes, this is the test that has to change
// with it.
void NoSnoopsAreEverSent() {
  Fixture f;
  f.node.NextReq(MakeReq(ReqOp::ReadUnique, kBase, kLineBytes, 0x701, true));
  const Sent sent = Drain(f.node);
  ExpectEq("snoops", sent.snp.size(), 0);
}

}  // namespace

int main() {
  FullLineReadIsTwoBeats();
  ReadEchoesIdentifiers();
  CompDataCarriesOddByteParity();
  ReadRespDependsOnTheOpcode();
  SubBeatReadIsOneBeatWithTheRightDataId();
  CompAckRetiresTheTransaction();
  ReadWithoutCompAckRetiresImmediately();

  WriteBackFullLandsInMemory();
  PartialWriteHonoursByteEnables();
  WriteDataCancelWritesNothing();

  DatalessRequestsGetComp();

  UnsupportedRequestIsAnsweredAndCounted();
  StrayCompAckIsCounted();
  StrayWriteDataIsCounted();
  NoSnoopsAreEverSent();

  if (failures != 0) {
    std::printf("%d failures\n", failures);
    return 1;
  }
  std::printf(
      "chi::HomeNode: reads, writes, dataless requests and the error paths all as stated\n");
  return 0;
}
