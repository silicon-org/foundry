// The request node against the home node, with no RTL and no fabric.
//
// Two models that were written separately, wired mouth to ear: whatever one
// sends, the other receives, in the same call stack and in the same
// millisecond. If they agree here then they agree about CHI, and any later
// failure with a mesh between them is the mesh's.
//
// That ordering is the whole reason this file exists before the system test. A
// transaction crossing sixteen crosspoints has a great many places to go wrong,
// and "the requester and the responder disagree about which identifier a
// CompAck carries" should not be one of the candidates by then.

#include "hardware/vip/chi/chi_request_node.h"

#include <cstdint>
#include <cstdio>
#include <span>
#include <string>
#include <vector>

#include "hardware/vip/chi/chi_home_node.h"
#include "hardware/vip/common/memory.h"

namespace {

using vip::chi::Dat;
using vip::chi::HomeNode;
using vip::chi::Req;
using vip::chi::RequestNode;
using vip::chi::Rsp;
using vip::chi::Snp;

constexpr std::uint32_t kHomeId = 0x2A;
constexpr std::uint32_t kRequesterId = 0x15;
constexpr std::uint64_t kBase = 0x8000'0000;
constexpr unsigned kLineBytes = 64;

int failures = 0;

void Fail(const std::string& what) {
  std::fprintf(stderr, "FAIL: %s\n", what.c_str());
  ++failures;
}

void Expect(bool condition, const std::string& what) {
  if (!condition) Fail(what);
}

// Moves every flit either model has ready, until both are idle or the budget
// runs out. No timing and no ordering beyond "requests before responses",
// because neither model has any: they are functions from flits to flits, and a
// fabric is what would give them a schedule.
void Settle(RequestNode& rn, HomeNode& hn, int budget = 10000) {
  for (int step = 0; step < budget; ++step) {
    bool moved = false;

    Req req;
    while (rn.NextTxReq(&req)) {
      hn.NextReq(req);
      moved = true;
    }
    Rsp rsp;
    while (rn.NextTxRsp(&rsp)) {
      hn.NextRsp(rsp);
      moved = true;
    }
    Dat dat;
    while (rn.NextTxDat(&dat)) {
      hn.NextDat(dat);
      moved = true;
    }
    Rsp from_home;
    while (hn.NextTxRsp(&from_home)) {
      rn.NextRsp(from_home);
      moved = true;
    }
    Dat data_home;
    while (hn.NextTxDat(&data_home)) {
      rn.NextDat(data_home);
      moved = true;
    }
    Snp snoop;
    while (hn.NextTxSnp(&snoop)) {
      rn.NextSnp(snoop);
      moved = true;
    }

    if (!moved) return;
  }
  Fail("the two models never settled");
}

struct Pair {
  vip::SparseMemory memory;
  HomeNode hn{HomeNode::Config{kHomeId, "test.hn", kLineBytes}, memory};
  // The last field is what a read of memory nobody has written returns:
  // SparseMemory fills with 0xFF so that an untouched byte is conspicuous.
  RequestNode rn{RequestNode::Config{kRequesterId, "test.rn", kLineBytes, 8, 0xFF}};
};

// Every byte the requester says it wrote is in the home node's memory, and
// nothing it did not write has appeared there.
void ExpectMemoryMatches(Pair& pair, const std::string& what) {
  for (const auto& [address, want] : pair.rn.expectation()) {
    std::uint8_t got = 0;
    pair.memory.Read(address, std::span<std::uint8_t>(&got, 1));
    if (got != want) {
      Fail(what + ": memory at " + std::to_string(address) + " is " + std::to_string(got) +
           ", the requester wrote " + std::to_string(want));
      return;
    }
  }
}

void ExpectClean(Pair& pair, const std::string& what) {
  Expect(pair.rn.stats().mismatches == 0, what + ": read data did not match");
  Expect(pair.rn.stats().unexpected == 0,
         what + ": the requester got something it never asked for");
  Expect(pair.hn.stats().unsupported == 0,
         what + ": the home node was sent something it cannot do");
  Expect(pair.rn.Outstanding() == 0, what + ": a transaction never finished");
  Expect(pair.hn.Outstanding() == 0, what + ": the home node is still holding a transaction");
  Expect(pair.rn.Idle(), what + ": the requester has work left");
}

////////////////////////////////////////////////////////////////////////////////

// A read of memory nobody has written returns the fill byte, and the requester
// expects it. Worth its own case because it is the only one where the
// expectation comes from the absence of a write rather than from a write.
void ReadOfUntouchedMemory() {
  Pair pair;
  pair.rn.Read(kBase, kLineBytes, kHomeId);
  Settle(pair.rn, pair.hn);

  Expect(pair.rn.stats().reads == 1, "read: one request");
  Expect(pair.rn.stats().completed == 1, "read: one completion");
  Expect(pair.rn.stats().read_beats == 2, "read: a 64-byte line is two 32-byte beats");
  Expect(pair.hn.stats().comp_acks == 1, "read: the home node saw the CompAck");
  ExpectClean(pair, "read");
}

// The round trip that matters: write a line, read it back, and require the
// bytes to be the ones that were sent. This is what a fabric later has to not
// break.
void WriteThenReadBack() {
  Pair pair;
  pair.rn.Write(kBase, kLineBytes, kHomeId);
  Settle(pair.rn, pair.hn);
  ExpectMemoryMatches(pair, "write");

  pair.rn.Read(kBase, kLineBytes, kHomeId);
  Settle(pair.rn, pair.hn);

  Expect(pair.rn.stats().writes == 1, "write: one request");
  Expect(pair.rn.stats().write_beats == 2, "write: two beats");
  Expect(pair.rn.stats().reads == 1, "read back: one request");
  ExpectClean(pair, "write then read back");
}

// A beat-sized transfer rather than a line-sized one, so that the beat count
// and the DataID arithmetic are exercised at both sizes.
void HalfLineTransfers() {
  Pair pair;
  pair.rn.Write(kBase + kLineBytes, 32, kHomeId);
  Settle(pair.rn, pair.hn);
  pair.rn.Read(kBase + kLineBytes, 32, kHomeId);
  Settle(pair.rn, pair.hn);

  Expect(pair.rn.stats().write_beats == 1, "half line: one write beat");
  Expect(pair.rn.stats().read_beats == 1, "half line: one read beat");
  ExpectMemoryMatches(pair, "half line");
  ExpectClean(pair, "half line");
}

// The second beat of a line, which is where a DataID computed from the wrong
// base would put bytes 32 bytes away from where they belong and a read of the
// same address would still agree with it. Reading the *other* half is what
// catches that.
void SecondBeatLandsWhereItShould() {
  Pair pair;
  pair.rn.Write(kBase, kLineBytes, kHomeId);
  Settle(pair.rn, pair.hn);

  std::vector<std::uint8_t> got(kLineBytes, 0);
  pair.memory.Read(kBase, std::span<std::uint8_t>(got));
  for (unsigned offset = 0; offset < kLineBytes; ++offset) {
    if (got[offset] != pair.rn.PatternAt(kBase + offset)) {
      Fail("second beat: byte " + std::to_string(offset) + " is not where it was addressed");
      return;
    }
  }
}

void DatalessCompletes() {
  Pair pair;
  pair.rn.Dataless(kBase, kHomeId);
  Settle(pair.rn, pair.hn);

  Expect(pair.rn.stats().dataless == 1, "dataless: one request");
  Expect(pair.rn.stats().completed == 1, "dataless: one completion");
  Expect(pair.hn.stats().dataless == 1, "dataless: the home node saw it");
  ExpectClean(pair, "dataless");
}

// Many transactions in flight at once, over several lines, mixed. The
// identifiers are what this is really about: with eight outstanding, a TxnID
// reused before its transaction retired would cross two answers over.
void ManyOutstanding() {
  Pair pair;
  constexpr unsigned kLines = 32;

  for (unsigned line = 0; line < kLines; ++line) {
    pair.rn.Write(kBase + line * kLineBytes, kLineBytes, kHomeId);
  }
  Settle(pair.rn, pair.hn);
  for (unsigned line = 0; line < kLines; ++line) {
    pair.rn.Read(kBase + line * kLineBytes, kLineBytes, kHomeId);
  }
  Settle(pair.rn, pair.hn);

  Expect(pair.rn.stats().writes == kLines, "many: every write issued");
  Expect(pair.rn.stats().reads == kLines, "many: every read issued");
  Expect(pair.rn.stats().completed == 2 * kLines, "many: everything completed");
  ExpectMemoryMatches(pair, "many");
  ExpectClean(pair, "many");
}

// A requester that caches nothing still has to answer a snoop, because a home
// node that never gets a reply stalls. Driven directly, since this home node
// has no directory and so never sends one.
void SnoopIsAnswered() {
  Pair pair;
  Snp snoop{};
  snoop.SrcID() = static_cast<Snp::srcid_t>(kHomeId);
  snoop.TxnID() = static_cast<Snp::txnid_t>(0x123);
  snoop.Opcode() = static_cast<Snp::opcode_t>(vip::chi::chiron::Opcodes::SNP::SnpShared);
  pair.rn.NextSnp(snoop);

  Rsp reply;
  Expect(pair.rn.NextTxRsp(&reply), "snoop: an answer was produced");
  Expect(static_cast<unsigned>(reply.Opcode()) == vip::chi::chiron::Opcodes::RSP::SnpResp,
         "snoop: answered with SnpResp");
  Expect(static_cast<unsigned>(reply.TxnID()) == 0x123, "snoop: the identifier is echoed");
  Expect(static_cast<unsigned>(reply.TgtID()) == kHomeId, "snoop: addressed to the snooper");
  Expect(pair.rn.stats().snoops == 1, "snoop: counted");
}

}  // namespace

int main() {
  ReadOfUntouchedMemory();
  WriteThenReadBack();
  HalfLineTransfers();
  SecondBeatLandsWhereItShould();
  DatalessCompletes();
  ManyOutstanding();
  SnoopIsAnswered();

  if (failures != 0) {
    std::fprintf(stderr, "%d checks failed\n", failures);
    return 1;
  }
  std::printf("the request node and the home node agree about CHI\n");
  return 0;
}
