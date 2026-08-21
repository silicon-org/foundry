// A CHI home node, as a function from flits to flits.
//
// No wires, no simulator, no Verilator header: this is where a
// ReadNotSharedDirty becomes two CompData beats and a WriteBackFull becomes a
// CompDBIDResp followed by a write to memory. The link that carries those flits
// is SystemVerilog, on the other side of a DPI boundary, and it knows nothing
// about any of this. See //hardware/vip/README.md.
//
// The consequence worth the trouble is that the test which covers every opcode
// this node supports needs no RTL and runs in milliseconds. A bug found there
// is a bug not found in a 1868-module simulation.
//
// One simplification runs through the whole file and it is the system's, not a
// shortcut: there is exactly one RN-F on this link. Nothing else holds a copy of
// any line, so this node never issues a snoop, and the directory that would
// otherwise be its bulk does not exist. A second requester means a directory and
// a snoop path, and the shape below -- flits in, flits out, no simulator -- is
// what makes that a change to one file.

#ifndef HARDWARE_VIP_CHI_CHI_HOME_NODE_H_
#define HARDWARE_VIP_CHI_CHI_HOME_NODE_H_

#include <cstdint>
#include <deque>
#include <memory>
#include <string>
#include <unordered_map>
#include <vector>

#include "hardware/vip/chi/chi_flit.h"
#include "hardware/vip/common/logging.h"
#include "hardware/vip/common/memory.h"

namespace vip::chi {

class HomeNode {
 public:
  struct Config {
    // Published as SrcID on everything this node sends, and as HomeNID on
    // CompData so that the requester knows where to send its CompAck.
    std::uint32_t node_id = 0;

    // The logger's name, so that two home nodes in one simulation can be turned
    // up separately.
    std::string name = "chi.hn";

    // Cache line size. Sets how many DAT beats a full-line transfer takes at
    // this link's data width.
    unsigned line_bytes = 64;
  };

  // Counters a test can assert on, and a run can be judged by. `unsupported` is
  // the one that matters: a request this node does not understand is answered
  // with an error rather than ignored, and a test that ends with a non-zero
  // count here has been lied to by a passing simulation.
  struct Stats {
    std::uint64_t reads = 0;
    std::uint64_t writes = 0;
    std::uint64_t dataless = 0;
    std::uint64_t comp_acks = 0;
    std::uint64_t write_beats = 0;
    std::uint64_t unsupported = 0;
  };

  HomeNode(Config config, MemoryBackend& memory);

  // Flits arriving from the request node.
  void NextReq(const Req& flit);
  void NextRsp(const Rsp& flit);
  void NextDat(const Dat& flit);

  // Flits to send. Each returns false when there is nothing waiting, and
  // removes what it returns from the queue -- so a caller that asks must send.
  bool NextTxRsp(Rsp* flit);
  bool NextTxDat(Dat* flit);
  bool NextTxSnp(Snp* flit);

  const Stats& stats() const { return stats_; }

  // Transactions opened and not yet retired. A run that ends with any of these
  // outstanding ended in the middle of something.
  std::size_t Outstanding() const { return transactions_.size(); }

 private:
  // What this node remembers between the request and whatever finishes it.
  struct Transaction {
    std::uint32_t requester = 0;      // the RN's SrcID, our TgtID in reply
    std::uint32_t requester_txn = 0;  // the RN's TxnID, echoed back
    std::uint32_t dbid = 0;           // ours, and what write data and CompAck carry
    std::uint64_t address = 0;
    unsigned size_bytes = 0;
    unsigned opcode = 0;
    bool expects_comp_ack = false;

    // Write data still to come, and where to put it when it does.
    unsigned data_beats_expected = 0;
    unsigned data_beats_seen = 0;
  };

  void HandleRead(const Req& flit);
  void HandleWrite(const Req& flit);
  void HandleDataless(const Req& flit);
  void HandleCompAck(const Rsp& flit);
  void HandleWriteData(const Dat& flit);

  // A transaction identifier this node has not got outstanding. Twelve bits,
  // handed out in order, skipping any still in use.
  std::uint32_t AllocateDbid();

  // The common fields of anything this node sends back to `transaction`.
  Rsp MakeRsp(const Transaction& transaction, unsigned opcode, unsigned resp) const;

  // Sends the data covering the transaction's request, as however many beats
  // the link's width takes.
  void SendCompData(const Transaction& transaction, unsigned resp);

  void Retire(std::uint32_t dbid);

  Config config_;
  MemoryBackend& memory_;
  std::shared_ptr<spdlog::logger> log_;

  std::unordered_map<std::uint32_t, Transaction> transactions_;
  std::uint32_t next_dbid_ = 0;

  std::deque<Rsp> tx_rsp_;
  std::deque<Dat> tx_dat_;

  Stats stats_;
};

}  // namespace vip::chi

#endif  // HARDWARE_VIP_CHI_CHI_HOME_NODE_H_
