#include "hardware/vip/chi/chi_home_node.h"

#include <algorithm>
#include <array>
#include <cstdint>
#include <span>

namespace vip::chi {
namespace {

namespace ReqOp = chiron::Opcodes::REQ;
namespace RspOp = chiron::Opcodes::RSP;
namespace DatOp = chiron::Opcodes::DAT;
namespace Resps = chiron::Resps;
namespace RespErrs = chiron::RespErrs;

// Bytes in one DAT flit.
constexpr unsigned kBeatBytes = FlitConfig::dataWidth / 8;

// DataID counts 128-bit chunks, whatever the link's data width, so a 256-bit
// link uses 0 and 2 for the two halves of a 64-byte line.
constexpr unsigned kDataIdBytes = 16;

// CHI encodes a transfer size as its base-2 logarithm.
unsigned SizeToBytes(unsigned size_field) { return 1u << size_field; }

bool IsRead(unsigned opcode) {
  switch (opcode) {
    case ReqOp::ReadNoSnp:
    case ReqOp::ReadOnce:
    case ReqOp::ReadOnceCleanInvalid:
    case ReqOp::ReadOnceMakeInvalid:
    case ReqOp::ReadClean:
    case ReqOp::ReadShared:
    case ReqOp::ReadNotSharedDirty:
    case ReqOp::ReadUnique:
    case ReqOp::MakeReadUnique:
    case ReqOp::ReadPreferUnique: return true;
    default: return false;
  }
}

// A read whose requester may keep the line. The rest get CompData_I, which says
// "here are the bytes, do not cache them" -- correct for ReadOnce by definition
// and for ReadNoSnp because that is how uncached and device traffic arrives.
bool ReadMayCache(unsigned opcode) {
  switch (opcode) {
    case ReqOp::ReadClean:
    case ReqOp::ReadShared:
    case ReqOp::ReadNotSharedDirty:
    case ReqOp::ReadUnique:
    case ReqOp::MakeReadUnique:
    case ReqOp::ReadPreferUnique: return true;
    default: return false;
  }
}

// A request that will be followed by write data. Both kinds are answered the
// same way -- CompDBIDResp, then wait -- and they differ only in what the
// requester's cache does afterwards, which with one requester is nothing this
// node has to track.
bool IsWrite(unsigned opcode) {
  switch (opcode) {
    // Copyback: the requester held the line and is giving it up.
    case ReqOp::WriteBackFull:
    case ReqOp::WriteBackPtl:
    case ReqOp::WriteCleanFull:
    case ReqOp::WriteEvictFull:
    case ReqOp::WriteEvictOrEvict:
    // Immediate: the requester never held it.
    case ReqOp::WriteNoSnpFull:
    case ReqOp::WriteNoSnpPtl:
    case ReqOp::WriteUniqueFull:
    case ReqOp::WriteUniquePtl: return true;
    default: return false;
  }
}

// A request with no data in either direction. Every one of them is a statement
// about a cache this node does not have to model, so every one of them is a
// Comp -- what differs is the state the requester is left in.
bool IsDataless(unsigned opcode) {
  switch (opcode) {
    case ReqOp::Evict:
    case ReqOp::CleanUnique:
    case ReqOp::MakeUnique:
    case ReqOp::CleanShared:
    case ReqOp::CleanInvalid:
    case ReqOp::MakeInvalid:
    case ReqOp::CleanSharedPersist: return true;
    default: return false;
  }
}

// The state the requester ends a dataless request in.
unsigned DatalessResp(unsigned opcode) {
  switch (opcode) {
    // The requester asked for the line to itself and nobody else has it.
    case ReqOp::CleanUnique:
    case ReqOp::MakeUnique: return Resps::UC;
    default: return Resps::I;
  }
}

// One odd-parity bit per byte, as CHI defines DataCheck.
//
// Required, not optional: CoupledL2 checks every beat, and zero reads as *even*
// parity rather than as "unused". Getting this wrong marks every line corrupt
// and surfaces far away, as a hardware-error exception on the first instruction
// fetched -- see tasks/xs-cluster-tb.md.
Dat::datacheck_t DataCheckOf(std::span<const std::uint8_t> bytes) {
  Dat::datacheck_t check = 0;
  for (unsigned i = 0; i < bytes.size(); ++i)
    if (__builtin_parity(bytes[i]) == 0) check |= Dat::datacheck_t{1} << i;
  return check;
}

}  // namespace

HomeNode::HomeNode(Config config, MemoryBackend& memory)
    : config_(std::move(config)), memory_(memory), log_(Logger(config_.name)) {
  log_->debug("home node {} up, {}-byte lines, {}-byte beats", config_.node_id, config_.line_bytes,
              kBeatBytes);
}

std::uint32_t HomeNode::AllocateDbid() {
  constexpr std::uint32_t kSpace = 1u << Rsp::DBID_WIDTH;
  for (std::uint32_t tried = 0; tried < kSpace; ++tried) {
    const std::uint32_t candidate = next_dbid_;
    next_dbid_ = (next_dbid_ + 1) % kSpace;
    if (transactions_.find(candidate) == transactions_.end()) return candidate;
  }
  // Every one of 4096 identifiers outstanding at once means nothing is ever
  // being retired, which is a bug in this file rather than a busy link.
  log_->error("all {} transaction identifiers are outstanding", kSpace);
  return 0;
}

Rsp HomeNode::MakeRsp(const Transaction& transaction, unsigned opcode, unsigned resp) const {
  Rsp flit{};
  flit.QoS() = 0;
  flit.TgtID() = static_cast<Rsp::tgtid_t>(transaction.requester);
  flit.SrcID() = static_cast<Rsp::srcid_t>(config_.node_id);
  flit.TxnID() = static_cast<Rsp::txnid_t>(transaction.requester_txn);
  flit.Opcode() = static_cast<Rsp::opcode_t>(opcode);
  flit.RespErr() = RespErrs::OK;
  flit.Resp() = static_cast<Rsp::resp_t>(resp);
  flit.DBID() = static_cast<Rsp::dbid_t>(transaction.dbid);
  return flit;
}

void HomeNode::SendCompData(const Transaction& transaction, unsigned resp) {
  // The beats cover the naturally aligned regions the request touches. A
  // full-line read is two of them; anything smaller than a beat is one, holding
  // the whole aligned region the request falls inside.
  const std::uint64_t line_base = transaction.address & ~std::uint64_t{config_.line_bytes - 1};
  const std::uint64_t first = (transaction.address & ~std::uint64_t{kBeatBytes - 1});
  const unsigned beats = std::max(1u, transaction.size_bytes / kBeatBytes);

  for (unsigned beat = 0; beat < beats; ++beat) {
    const std::uint64_t at = first + beat * kBeatBytes;

    Dat flit{};
    flit.QoS() = 0;
    flit.TgtID() = static_cast<Dat::tgtid_t>(transaction.requester);
    flit.SrcID() = static_cast<Dat::srcid_t>(config_.node_id);
    flit.TxnID() = static_cast<Dat::txnid_t>(transaction.requester_txn);
    // Where the requester sends its CompAck, and under which identifier.
    flit.HomeNID() = static_cast<Dat::homenid_t>(config_.node_id);
    flit.DBID() = static_cast<Dat::dbid_t>(transaction.dbid);
    flit.Opcode() = static_cast<Dat::opcode_t>(DatOp::CompData);
    flit.RespErr() = RespErrs::OK;
    flit.Resp() = static_cast<Dat::resp_t>(resp);
    flit.DataID() = static_cast<Dat::dataid_t>((at - line_base) / kDataIdBytes);
    flit.BE() = static_cast<Dat::be_t>(~Dat::be_t{0});

    std::array<std::uint8_t, kBeatBytes> bytes{};
    memory_.Read(at, bytes);
    for (unsigned word = 0; word < kBeatBytes / 8; ++word) {
      std::uint64_t value = 0;
      for (unsigned byte = 0; byte < 8; ++byte)
        value |= static_cast<std::uint64_t>(bytes[word * 8 + byte]) << (byte * 8);
      flit.Data()[word] = value;
    }
    flit.DataCheck() = DataCheckOf(bytes);

    log_->trace("tx CompData txn={:#x} addr={:#x} dataid={} resp={:#x}", transaction.requester_txn,
                at, static_cast<unsigned>(flit.DataID()), resp);
    tx_dat_.push_back(flit);
  }
}

void HomeNode::NextReq(const Req& flit) {
  const unsigned opcode = static_cast<unsigned>(flit.Opcode());
  log_->trace("rx REQ opcode={:#x} src={:#x} txn={:#x} addr={:#x} size={} eca={}", opcode,
              static_cast<unsigned>(flit.SrcID()), static_cast<unsigned>(flit.TxnID()),
              static_cast<std::uint64_t>(flit.Addr()), static_cast<unsigned>(flit.Size()),
              static_cast<unsigned>(flit.ExpCompAck()));

  if (IsRead(opcode)) {
    HandleRead(flit);
  } else if (IsWrite(opcode)) {
    HandleWrite(flit);
  } else if (IsDataless(opcode)) {
    HandleDataless(flit);
  } else {
    // Loudly, and with an answer, because a request left unanswered stalls the
    // requester and the failure surfaces as a timeout somewhere else entirely.
    ++stats_.unsupported;
    log_->error("REQ opcode {:#x} is not implemented; answering with a non-data error", opcode);
    Transaction transaction;
    transaction.requester = static_cast<std::uint32_t>(flit.SrcID());
    transaction.requester_txn = static_cast<std::uint32_t>(flit.TxnID());
    transaction.dbid = AllocateDbid();
    Rsp response = MakeRsp(transaction, RspOp::Comp, Resps::I);
    response.RespErr() = RespErrs::NDERR;
    tx_rsp_.push_back(response);
  }
}

void HomeNode::HandleRead(const Req& flit) {
  Transaction transaction;
  transaction.requester = static_cast<std::uint32_t>(flit.SrcID());
  transaction.requester_txn = static_cast<std::uint32_t>(flit.TxnID());
  transaction.dbid = AllocateDbid();
  transaction.address = static_cast<std::uint64_t>(flit.Addr());
  transaction.size_bytes = SizeToBytes(static_cast<unsigned>(flit.Size()));
  transaction.opcode = static_cast<unsigned>(flit.Opcode());
  transaction.expects_comp_ack = flit.ExpCompAck() != 0;

  ++stats_.reads;
  SendCompData(transaction, ReadMayCache(transaction.opcode) ? Resps::UC : Resps::I);

  // A read that expects a CompAck is not finished until it arrives; one that
  // does not is finished the moment the data is queued.
  if (transaction.expects_comp_ack)
    transactions_.emplace(transaction.dbid, transaction);
  else
    log_->debug("read {:#x} complete, {} bytes, no CompAck expected", transaction.address,
                transaction.size_bytes);
}

void HomeNode::HandleWrite(const Req& flit) {
  Transaction transaction;
  transaction.requester = static_cast<std::uint32_t>(flit.SrcID());
  transaction.requester_txn = static_cast<std::uint32_t>(flit.TxnID());
  transaction.dbid = AllocateDbid();
  transaction.address = static_cast<std::uint64_t>(flit.Addr());
  transaction.size_bytes = SizeToBytes(static_cast<unsigned>(flit.Size()));
  transaction.opcode = static_cast<unsigned>(flit.Opcode());
  transaction.data_beats_expected = std::max(1u, transaction.size_bytes / kBeatBytes);

  ++stats_.writes;
  transactions_.emplace(transaction.dbid, transaction);

  // CompDBIDResp says two things at once: the request is complete, and this is
  // the identifier to send the data under. Splitting it into a Comp and a
  // DBIDResp is legal and buys nothing here.
  log_->debug("write {:#x}, {} bytes, {} beats, dbid={:#x}", transaction.address,
              transaction.size_bytes, transaction.data_beats_expected, transaction.dbid);
  tx_rsp_.push_back(MakeRsp(transaction, RspOp::CompDBIDResp, Resps::I));
}

void HomeNode::HandleDataless(const Req& flit) {
  Transaction transaction;
  transaction.requester = static_cast<std::uint32_t>(flit.SrcID());
  transaction.requester_txn = static_cast<std::uint32_t>(flit.TxnID());
  transaction.dbid = AllocateDbid();
  transaction.opcode = static_cast<unsigned>(flit.Opcode());
  transaction.expects_comp_ack = flit.ExpCompAck() != 0;

  ++stats_.dataless;
  log_->debug("dataless opcode={:#x} addr={:#x}", transaction.opcode,
              static_cast<std::uint64_t>(flit.Addr()));
  tx_rsp_.push_back(MakeRsp(transaction, RspOp::Comp, DatalessResp(transaction.opcode)));

  if (transaction.expects_comp_ack) transactions_.emplace(transaction.dbid, transaction);
}

void HomeNode::NextRsp(const Rsp& flit) {
  const unsigned opcode = static_cast<unsigned>(flit.Opcode());
  log_->trace("rx RSP opcode={:#x} txn={:#x}", opcode, static_cast<unsigned>(flit.TxnID()));

  if (opcode == RspOp::CompAck) {
    HandleCompAck(flit);
    return;
  }
  ++stats_.unsupported;
  log_->error("RSP opcode {:#x} is not implemented", opcode);
}

void HomeNode::HandleCompAck(const Rsp& flit) {
  // A CompAck carries the DBID the completion was sent with, in its TxnID.
  const std::uint32_t dbid = static_cast<std::uint32_t>(flit.TxnID());
  ++stats_.comp_acks;

  if (transactions_.find(dbid) == transactions_.end()) {
    ++stats_.unsupported;
    log_->error("CompAck for dbid {:#x}, which is not outstanding", dbid);
    return;
  }
  log_->debug("CompAck retires dbid={:#x}", dbid);
  Retire(dbid);
}

void HomeNode::NextDat(const Dat& flit) {
  const unsigned opcode = static_cast<unsigned>(flit.Opcode());
  log_->trace("rx DAT opcode={:#x} txn={:#x} dataid={}", opcode,
              static_cast<unsigned>(flit.TxnID()), static_cast<unsigned>(flit.DataID()));

  switch (opcode) {
    case DatOp::CopyBackWrData:
    case DatOp::NonCopyBackWrData:
    case DatOp::NCBWrDataCompAck: HandleWriteData(flit); return;
    case DatOp::WriteDataCancel:
      // The requester changed its mind: the write is complete and no bytes move.
      // Legal for a copyback whose line turned out to be clean.
      log_->debug("WriteDataCancel retires dbid={:#x}", static_cast<unsigned>(flit.TxnID()));
      Retire(static_cast<std::uint32_t>(flit.TxnID()));
      return;
    default:
      ++stats_.unsupported;
      log_->error("DAT opcode {:#x} is not implemented", opcode);
      return;
  }
}

void HomeNode::HandleWriteData(const Dat& flit) {
  // Write data comes back under the DBID this node handed out, not under the
  // requester's own transaction identifier.
  const std::uint32_t dbid = static_cast<std::uint32_t>(flit.TxnID());
  const auto it = transactions_.find(dbid);
  if (it == transactions_.end()) {
    ++stats_.unsupported;
    log_->error("write data for dbid {:#x}, which is not outstanding", dbid);
    return;
  }
  Transaction& transaction = it->second;

  const std::uint64_t line_base = transaction.address & ~std::uint64_t{config_.line_bytes - 1};
  const std::uint64_t at = line_base + static_cast<unsigned>(flit.DataID()) * kDataIdBytes;

  std::array<std::uint8_t, kBeatBytes> bytes{};
  std::array<std::uint8_t, kBeatBytes> enable{};
  const auto be = static_cast<std::uint64_t>(flit.BE());
  for (unsigned word = 0; word < kBeatBytes / 8; ++word) {
    const std::uint64_t value = flit.Data()[word];
    for (unsigned byte = 0; byte < 8; ++byte) {
      const unsigned index = word * 8 + byte;
      bytes[index] = static_cast<std::uint8_t>(value >> (byte * 8));
      enable[index] = static_cast<std::uint8_t>((be >> index) & 1);
    }
  }
  memory_.Write(at, bytes, enable);

  ++stats_.write_beats;
  ++transaction.data_beats_seen;
  log_->trace("wrote beat {} of {} at {:#x}, be={:#x}", transaction.data_beats_seen,
              transaction.data_beats_expected, at, be);

  if (transaction.data_beats_seen < transaction.data_beats_expected) return;

  log_->debug("write {:#x} complete after {} beats", transaction.address,
              transaction.data_beats_seen);

  // NCBWrDataCompAck is the requester saying "and this is my CompAck too", so
  // there is no separate response to wait for.
  Retire(dbid);
}

void HomeNode::Retire(std::uint32_t dbid) { transactions_.erase(dbid); }

bool HomeNode::NextTxRsp(Rsp* flit) {
  if (tx_rsp_.empty()) return false;
  *flit = tx_rsp_.front();
  tx_rsp_.pop_front();
  return true;
}

bool HomeNode::NextTxDat(Dat* flit) {
  if (tx_dat_.empty()) return false;
  *flit = tx_dat_.front();
  tx_dat_.pop_front();
  return true;
}

bool HomeNode::NextTxSnp(Snp* flit) {
  // One RN-F on this link, so nothing else holds a copy of any line and there
  // is never anything to snoop. The channel exists because the link has one.
  (void)flit;
  return false;
}

}  // namespace vip::chi
