// A CHI request node, as a function from flits to flits.
//
// The mirror of chi_home_node.h and built to the same shape: no wires, no
// simulator, no Verilator header. What it adds is the half of a CHI transaction
// nobody had yet -- something that *starts* one. Until now the only agent in
// this repository answered requests, which is why a fabric could be tested for
// carrying flits and not for carrying transactions.
//
// It is a traffic generator and a checker at once. Work is queued by a
// testbench, turned into REQ flits as identifiers come free, and each response
// is matched against what was asked for. Read data is compared against what
// this node believes memory holds, so a fabric that delivers the right flit to
// the wrong place, or the right bytes in the wrong order, fails here rather
// than in a later run that happens to look at the byte.
//
// What it deliberately does not do is cache anything. A line is never held, so
// no snoop can be owed a reply beyond a courteous one, and there is no
// directory here or in chi_home_node for the two of them to disagree about.
// Coherence between requesters is home-node work; this fabric is transport, and
// so is what verifies it.

#ifndef HARDWARE_VIP_CHI_CHI_REQUEST_NODE_H_
#define HARDWARE_VIP_CHI_CHI_REQUEST_NODE_H_

#include <cstdint>
#include <deque>
#include <map>
#include <memory>
#include <string>
#include <unordered_map>

#include "hardware/vip/chi/chi_flit.h"
#include "hardware/vip/common/logging.h"

namespace vip::chi {

class RequestNode {
 public:
  struct Config {
    // Published as SrcID on everything this node sends, and what a home node
    // addresses its answers to.
    std::uint32_t node_id = 0;

    // The logger's name, so that sixteen of these in one simulation can be
    // turned up one at a time.
    std::string name = "chi.rn";

    // Cache line size. Sets how many DAT beats a full-line transfer takes at
    // this link's data width.
    unsigned line_bytes = 64;

    // Requests in flight at once. CHI allows one per TxnID and this node has
    // 4096 of those; the limit is here so a test can choose how hard to push,
    // which is the difference between measuring a fabric and flooding it.
    unsigned max_outstanding = 8;

    // What a read of memory this node has not written should return.
    //
    // Configured rather than assumed, because it belongs to whatever is behind
    // the home node and not to this one. `vip::SparseMemory` fills with 0xFF on
    // purpose -- an untouched byte should not look like a plausible value -- so
    // that is the default, and a test whose memory is preloaded says so.
    std::uint8_t untouched_byte = 0xFF;
  };

  // Counters a test can assert on. `mismatches` and `unexpected` are the ones
  // that matter: the first says the fabric moved the wrong bytes, the second
  // that it delivered something nobody asked for.
  struct Stats {
    std::uint64_t reads = 0;
    std::uint64_t writes = 0;
    std::uint64_t dataless = 0;
    std::uint64_t completed = 0;
    std::uint64_t read_beats = 0;
    std::uint64_t write_beats = 0;
    std::uint64_t snoops = 0;
    std::uint64_t mismatches = 0;
    std::uint64_t unexpected = 0;
  };

  explicit RequestNode(Config config);

  ////////////////////////////////////////////////////////////////////////////////
  // Work
  //
  // `target` is the home node that owns the address. Which one that is comes
  // from the System Address Map, which belongs to the system and not to this
  // node -- so the caller says, and this node does not have to be told the map.
  //
  // `bytes` must be a whole number of beats: 32 or 64 at this link's width.
  // Partial writes are a byte-enable problem rather than a fabric one, and
  // this node exists to exercise the fabric.
  ////////////////////////////////////////////////////////////////////////////////

  void Read(std::uint64_t address, unsigned bytes, std::uint32_t target);
  void Write(std::uint64_t address, unsigned bytes, std::uint32_t target);
  void Dataless(std::uint64_t address, std::uint32_t target);

  // Flits arriving from the home node.
  void NextRsp(const Rsp& flit);
  void NextDat(const Dat& flit);
  void NextSnp(const Snp& flit);

  // Flits to send. Each returns false when there is nothing waiting, and
  // removes what it returns -- so a caller that asks must send.
  bool NextTxReq(Req* flit);
  bool NextTxRsp(Rsp* flit);
  bool NextTxDat(Dat* flit);

  const Stats& stats() const { return stats_; }

  std::size_t Outstanding() const { return outstanding_.size(); }
  std::size_t Queued() const { return queued_.size(); }

  // Nothing left to send, nothing left to wait for. A run that ends otherwise
  // ended in the middle of a transaction, and the counters will not say so.
  bool Idle() const;

  // What this node believes memory holds where it has written. The test
  // compares the home node's memory against this at the end, which is the check
  // that the bytes went where they were addressed rather than merely somewhere.
  const std::map<std::uint64_t, std::uint8_t>& expectation() const { return expectation_; }

  // The byte this node writes at `address`. Deterministic, and different per
  // node, so a byte delivered from the wrong requester is visible as a
  // mismatch rather than as a coincidence.
  std::uint8_t PatternAt(std::uint64_t address) const;

 private:
  enum class Kind : std::uint8_t { Read, Write, Dataless };

  struct Work {
    Kind kind = Kind::Read;
    std::uint64_t address = 0;
    unsigned bytes = 0;
    std::uint32_t target = 0;
  };

  // What this node remembers between sending a request and finishing with it.
  struct Transaction {
    Work work;
    std::uint32_t txn_id = 0;

    // Learned from the home node's answer: where to send what comes next, and
    // under which identifier. A CompAck and write data both travel under the
    // home node's DBID and not under ours.
    std::uint32_t dbid = 0;
    std::uint32_t home_nid = 0;

    unsigned beats_expected = 0;
    unsigned beats_seen = 0;
    unsigned beats_sent = 0;
    bool expects_comp_ack = false;
  };

  std::uint32_t AllocateTxnId();
  Req MakeReq(const Transaction& transaction, unsigned opcode) const;
  void SendWriteData(Transaction& transaction);
  void Retire(std::uint32_t txn_id);

  // Beats a transfer of `bytes` takes, and the address the first one starts at.
  unsigned BeatsFor(unsigned bytes) const;

  Config config_;
  std::shared_ptr<spdlog::logger> log_;

  std::deque<Work> queued_;
  std::unordered_map<std::uint32_t, Transaction> outstanding_;
  std::uint32_t next_txn_id_ = 0;

  std::deque<Req> tx_req_;
  std::deque<Rsp> tx_rsp_;
  std::deque<Dat> tx_dat_;

  std::map<std::uint64_t, std::uint8_t> expectation_;

  Stats stats_;
};

}  // namespace vip::chi

#endif  // HARDWARE_VIP_CHI_CHI_REQUEST_NODE_H_
