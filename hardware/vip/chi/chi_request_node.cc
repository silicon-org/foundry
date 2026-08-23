#include "hardware/vip/chi/chi_request_node.h"

#include <algorithm>
#include <array>
#include <cstring>

namespace vip::chi {
namespace {

namespace ReqOp = chiron::Opcodes::REQ;
namespace RspOp = chiron::Opcodes::RSP;
namespace DatOp = chiron::Opcodes::DAT;
namespace RespErrs = chiron::RespErrs;

constexpr unsigned kBeatBytes = FlitConfig::dataWidth / 8;

// log2, for the Size field. CHI encodes a transfer size as its logarithm, so a
// 64-byte line is 6 and not 64.
unsigned BytesToSize(unsigned bytes) {
  unsigned size = 0;
  while ((1u << size) < bytes) ++size;
  return size;
}

}  // namespace

RequestNode::RequestNode(Config config) : config_(std::move(config)), log_(Logger(config_.name)) {
  log_->debug("request node {:#x}, {} byte lines, {} outstanding", config_.node_id,
              config_.line_bytes, config_.max_outstanding);
}

std::uint8_t RequestNode::PatternAt(std::uint64_t address) const {
  // Mixed enough that a byte from a neighbouring address or a neighbouring node
  // does not look like the right answer, and cheap enough to compute per byte.
  const std::uint64_t mixed = address * 0x9E3779B97F4A7C15ull + config_.node_id * 0x100000001B3ull;
  return static_cast<std::uint8_t>((mixed >> 29) ^ (mixed >> 13) ^ mixed);
}

unsigned RequestNode::BeatsFor(unsigned bytes) const { return std::max(1u, bytes / kBeatBytes); }

void RequestNode::Read(std::uint64_t address, unsigned bytes, std::uint32_t target) {
  queued_.push_back(Work{Kind::Read, address, bytes, target});
}

void RequestNode::Write(std::uint64_t address, unsigned bytes, std::uint32_t target) {
  // Recorded now rather than when the data is sent, so that a write which never
  // gets its data out still shows up as a missing byte at the end instead of
  // quietly agreeing with a memory that never received it.
  for (unsigned offset = 0; offset < bytes; ++offset) {
    expectation_[address + offset] = PatternAt(address + offset);
  }
  queued_.push_back(Work{Kind::Write, address, bytes, target});
}

void RequestNode::Dataless(std::uint64_t address, std::uint32_t target) {
  queued_.push_back(Work{Kind::Dataless, address, 0, target});
}

std::uint32_t RequestNode::AllocateTxnId() {
  constexpr std::uint32_t kSpace = 1u << 12;
  for (std::uint32_t tried = 0; tried < kSpace; ++tried) {
    const std::uint32_t candidate = next_txn_id_;
    next_txn_id_ = (next_txn_id_ + 1) % kSpace;
    if (outstanding_.find(candidate) == outstanding_.end()) return candidate;
  }
  log_->error("all {} transaction identifiers are outstanding", kSpace);
  return 0;
}

Req RequestNode::MakeReq(const Transaction& transaction, unsigned opcode) const {
  Req flit{};
  flit.QoS() = 0;
  flit.TgtID() = static_cast<Req::tgtid_t>(transaction.work.target);
  flit.SrcID() = static_cast<Req::srcid_t>(config_.node_id);
  flit.TxnID() = static_cast<Req::txnid_t>(transaction.txn_id);
  flit.Opcode() = static_cast<Req::opcode_t>(opcode);
  flit.Addr() = static_cast<Req::addr_t>(transaction.work.address);
  flit.Size() = static_cast<Req::ssize_t>(BytesToSize(std::max(1u, transaction.work.bytes)));
  flit.ExpCompAck() = transaction.expects_comp_ack ? 1 : 0;
  return flit;
}

bool RequestNode::NextTxReq(Req* flit) {
  if (!tx_req_.empty()) {
    *flit = tx_req_.front();
    tx_req_.pop_front();
    return true;
  }
  if (queued_.empty() || outstanding_.size() >= config_.max_outstanding) return false;

  Transaction transaction;
  transaction.work = queued_.front();
  queued_.pop_front();
  transaction.txn_id = AllocateTxnId();

  unsigned opcode = 0;
  switch (transaction.work.kind) {
    case Kind::Read:
      // ReadNoSnp: this node caches nothing, so asking for a snooped copy would
      // be a claim it cannot honour. CompAck is requested because it is the
      // half of the read handshake that would otherwise never be exercised.
      opcode = ReqOp::ReadNoSnp;
      transaction.expects_comp_ack = true;
      transaction.beats_expected = BeatsFor(transaction.work.bytes);
      ++stats_.reads;
      break;
    case Kind::Write:
      // WriteNoSnpFull, and no CompAck: the home node answers with a
      // CompDBIDResp and the write is finished by the last data beat.
      opcode = ReqOp::WriteNoSnpFull;
      transaction.beats_expected = BeatsFor(transaction.work.bytes);
      ++stats_.writes;
      break;
    case Kind::Dataless:
      opcode = ReqOp::CleanShared;
      transaction.expects_comp_ack = false;
      ++stats_.dataless;
      break;
  }

  *flit = MakeReq(transaction, opcode);
  log_->trace("tx REQ opcode={:#x} txn={:#x} addr={:#x} tgt={:#x}", opcode, transaction.txn_id,
              transaction.work.address, transaction.work.target);
  outstanding_.emplace(transaction.txn_id, transaction);
  return true;
}

void RequestNode::NextRsp(const Rsp& flit) {
  const unsigned opcode = static_cast<unsigned>(flit.Opcode());
  const std::uint32_t txn_id = static_cast<std::uint32_t>(flit.TxnID());
  log_->trace("rx RSP opcode={:#x} txn={:#x} dbid={:#x}", opcode, txn_id,
              static_cast<unsigned>(flit.DBID()));

  const auto it = outstanding_.find(txn_id);
  if (it == outstanding_.end()) {
    ++stats_.unexpected;
    log_->error("RSP opcode {:#x} for txn {:#x}, which is not outstanding", opcode, txn_id);
    return;
  }
  Transaction& transaction = it->second;

  if (static_cast<unsigned>(flit.RespErr()) != RespErrs::OK) {
    ++stats_.unexpected;
    log_->error("txn {:#x} answered with RespErr {:#x}", txn_id,
                static_cast<unsigned>(flit.RespErr()));
    return;
  }

  switch (opcode) {
    case RspOp::CompDBIDResp:
      // Both halves at once: the request is complete, and this is the
      // identifier the data travels under.
      transaction.dbid = static_cast<std::uint32_t>(flit.DBID());
      transaction.home_nid = static_cast<std::uint32_t>(flit.SrcID());
      SendWriteData(transaction);
      return;

    case RspOp::Comp:
      // A dataless request, finished. Nothing here caches, so the state it
      // leaves this node in is not something to record.
      ++stats_.completed;
      log_->debug("dataless txn {:#x} complete", txn_id);
      Retire(txn_id);
      return;

    case RspOp::DBIDResp:
      transaction.dbid = static_cast<std::uint32_t>(flit.DBID());
      transaction.home_nid = static_cast<std::uint32_t>(flit.SrcID());
      SendWriteData(transaction);
      return;

    default:
      ++stats_.unexpected;
      log_->error("RSP opcode {:#x} is not one this node asked for", opcode);
      return;
  }
}

void RequestNode::SendWriteData(Transaction& transaction) {
  const std::uint64_t line_base = transaction.work.address & ~std::uint64_t{config_.line_bytes - 1};
  const std::uint64_t first = transaction.work.address & ~std::uint64_t{kBeatBytes - 1};

  for (unsigned beat = 0; beat < transaction.beats_expected; ++beat) {
    const std::uint64_t at = first + beat * kBeatBytes;

    Dat flit{};
    flit.QoS() = 0;
    flit.TgtID() = static_cast<Dat::tgtid_t>(transaction.home_nid);
    flit.SrcID() = static_cast<Dat::srcid_t>(config_.node_id);
    // Under the home node's identifier, not ours.
    flit.TxnID() = static_cast<Dat::txnid_t>(transaction.dbid);
    flit.Opcode() = static_cast<Dat::opcode_t>(DatOp::NonCopyBackWrData);
    flit.RespErr() = RespErrs::OK;
    flit.DataID() = static_cast<Dat::dataid_t>((at - line_base) / kDataIdBytes);
    flit.BE() = static_cast<Dat::be_t>(~Dat::be_t{0});

    std::array<std::uint8_t, kBeatBytes> bytes{};
    for (unsigned index = 0; index < kBeatBytes; ++index) bytes[index] = PatternAt(at + index);
    for (unsigned word = 0; word < kBeatBytes / 8; ++word) {
      std::uint64_t value = 0;
      for (unsigned byte = 0; byte < 8; ++byte)
        value |= static_cast<std::uint64_t>(bytes[word * 8 + byte]) << (byte * 8);
      flit.Data()[word] = value;
    }
    flit.DataCheck() = DataCheckOf(bytes);

    log_->trace("tx WrData dbid={:#x} addr={:#x} dataid={}", transaction.dbid, at,
                static_cast<unsigned>(flit.DataID()));
    tx_dat_.push_back(flit);
    ++transaction.beats_sent;
    ++stats_.write_beats;
  }

  // The last beat is the end of a WriteNoSnp: the home node answers nothing
  // further, so there is nothing left to wait for.
  ++stats_.completed;
  log_->debug("write txn {:#x} complete, {} beats", transaction.txn_id, transaction.beats_sent);
  Retire(transaction.txn_id);
}

void RequestNode::NextDat(const Dat& flit) {
  const unsigned opcode = static_cast<unsigned>(flit.Opcode());
  const std::uint32_t txn_id = static_cast<std::uint32_t>(flit.TxnID());
  log_->trace("rx DAT opcode={:#x} txn={:#x} dataid={}", opcode, txn_id,
              static_cast<unsigned>(flit.DataID()));

  if (opcode != DatOp::CompData) {
    ++stats_.unexpected;
    log_->error("DAT opcode {:#x} is not one this node asked for", opcode);
    return;
  }

  const auto it = outstanding_.find(txn_id);
  if (it == outstanding_.end()) {
    ++stats_.unexpected;
    log_->error("CompData for txn {:#x}, which is not outstanding", txn_id);
    return;
  }
  Transaction& transaction = it->second;

  transaction.dbid = static_cast<std::uint32_t>(flit.DBID());
  transaction.home_nid = static_cast<std::uint32_t>(flit.HomeNID());

  // Where this beat belongs, from DataID rather than from a counter: the beats
  // of one read may be interleaved with anything else on the channel, and the
  // fabric is under no obligation to keep them adjacent.
  const std::uint64_t line_base = transaction.work.address & ~std::uint64_t{config_.line_bytes - 1};
  const std::uint64_t at = line_base + static_cast<unsigned>(flit.DataID()) * kDataIdBytes;

  for (unsigned word = 0; word < kBeatBytes / 8; ++word) {
    const std::uint64_t value = flit.Data()[word];
    for (unsigned byte = 0; byte < 8; ++byte) {
      const unsigned index = word * 8 + byte;
      const std::uint8_t got = static_cast<std::uint8_t>(value >> (byte * 8));

      // Anything this node has written, it expects back. Anything it has not is
      // whatever the memory behind the home node started as, which the caller
      // configured because it is not this node's to know.
      const std::uint64_t address = at + index;
      const auto known = expectation_.find(address);
      const std::uint8_t want =
          (known == expectation_.end()) ? config_.untouched_byte : known->second;

      if (got != want) {
        ++stats_.mismatches;
        log_->error("txn {:#x}: byte at {:#x} came back {:#04x}, expected {:#04x}", txn_id, address,
                    got, want);
      }
    }
  }

  ++stats_.read_beats;
  ++transaction.beats_seen;
  if (transaction.beats_seen < transaction.beats_expected) return;

  if (transaction.expects_comp_ack) {
    // A CompAck travels under the home node's DBID, back to the node that
    // published itself as HomeNID on the data.
    Rsp ack{};
    ack.QoS() = 0;
    ack.TgtID() = static_cast<Rsp::tgtid_t>(transaction.home_nid);
    ack.SrcID() = static_cast<Rsp::srcid_t>(config_.node_id);
    ack.TxnID() = static_cast<Rsp::txnid_t>(transaction.dbid);
    ack.Opcode() = static_cast<Rsp::opcode_t>(RspOp::CompAck);
    log_->trace("tx CompAck dbid={:#x} to {:#x}", transaction.dbid, transaction.home_nid);
    tx_rsp_.push_back(ack);
  }

  ++stats_.completed;
  log_->debug("read txn {:#x} complete, {} beats", txn_id, transaction.beats_seen);
  Retire(txn_id);
}

void RequestNode::NextSnp(const Snp& flit) {
  // This node caches nothing, so every snoop is answered SnpResp_I: it does not
  // have the line, it never had the line, and it is not about to take one.
  //
  // Answered rather than ignored. A snoop left unanswered stalls the home node
  // that sent it, and that surfaces as a timeout somewhere else entirely.
  ++stats_.snoops;
  log_->debug("rx SNP opcode={:#x} txn={:#x}", static_cast<unsigned>(flit.Opcode()),
              static_cast<unsigned>(flit.TxnID()));

  Rsp response{};
  response.QoS() = 0;
  response.TgtID() = static_cast<Rsp::tgtid_t>(flit.SrcID());
  response.SrcID() = static_cast<Rsp::srcid_t>(config_.node_id);
  response.TxnID() = static_cast<Rsp::txnid_t>(flit.TxnID());
  response.Opcode() = static_cast<Rsp::opcode_t>(RspOp::SnpResp);
  response.RespErr() = RespErrs::OK;
  response.Resp() = 0;  // I
  tx_rsp_.push_back(response);
}

bool RequestNode::NextTxRsp(Rsp* flit) {
  if (tx_rsp_.empty()) return false;
  *flit = tx_rsp_.front();
  tx_rsp_.pop_front();
  return true;
}

bool RequestNode::NextTxDat(Dat* flit) {
  if (tx_dat_.empty()) return false;
  *flit = tx_dat_.front();
  tx_dat_.pop_front();
  return true;
}

void RequestNode::Retire(std::uint32_t txn_id) { outstanding_.erase(txn_id); }

bool RequestNode::Idle() const {
  return queued_.empty() && outstanding_.empty() && tx_req_.empty() && tx_rsp_.empty() &&
         tx_dat_.empty();
}

}  // namespace vip::chi
