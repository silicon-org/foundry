#include "hardware/vip/chi/dpi/chi_rn_dpi.h"

#include <cstdint>
#include <map>
#include <memory>
#include <span>
#include <string>

#include "hardware/vip/common/logging.h"
#include "hardware/vip/common/vip_dpi.h"

// svdpi.h is not included, for the reason chi_hn_dpi.cc gives: rules_verilator
// builds the Verilated runtime under a configuration transition, and naming the
// target the header comes from would pull the wrong copy into half the
// testbenches. The two types are part of the DPI ABI and do not change.
using SvBitVecVal = std::uint32_t;
using SvBit = unsigned char;

namespace {

std::map<std::string, std::unique_ptr<vip::chi::RequestNode>>& Registry() {
  static std::map<std::string, std::unique_ptr<vip::chi::RequestNode>> registry;
  return registry;
}

vip::chi::RequestNode* Node(void* handle) {
  if (handle == nullptr) return nullptr;
  return static_cast<vip::chi::RequestNode*>(handle);
}

template <typename Flit>
bool PackForSimulator(const Flit& flit, SvBitVecVal* into) {
  std::uint32_t buffer[vip::chi::kWordsFor<Flit>] = {};
  if (!vip::chi::Pack(flit, buffer)) return false;
  for (std::size_t word = 0; word < (Flit::WIDTH + 31) / 32; ++word) into[word] = buffer[word];
  return true;
}

}  // namespace

namespace vip::chi {

RequestNode* RequestNodeNamed(const std::string& name) {
  const auto it = Registry().find(name);
  return it == Registry().end() ? nullptr : it->second.get();
}

}  // namespace vip::chi

extern "C" {

void* chi_rn_create(const char* name, std::uint32_t node_id, std::uint32_t line_bytes,
                    std::uint32_t max_outstanding) {
  const std::string key = name == nullptr ? "" : name;
  auto node = std::make_unique<vip::chi::RequestNode>(
      vip::chi::RequestNode::Config{node_id, key, line_bytes, max_outstanding});
  vip::chi::RequestNode* raw = node.get();
  Registry()[key] = std::move(node);
  return raw;
}

void* chi_rn_bind(const char* name) {
  const std::string key = name == nullptr ? "" : name;
  return vip::chi::RequestNodeNamed(key);
}

void chi_rn_read(void* handle, std::uint64_t address, std::uint32_t bytes, std::uint32_t target) {
  vip::chi::RequestNode* node = Node(handle);
  if (node != nullptr) node->Read(address, bytes, target);
}

void chi_rn_write(void* handle, std::uint64_t address, std::uint32_t bytes, std::uint32_t target) {
  vip::chi::RequestNode* node = Node(handle);
  if (node != nullptr) node->Write(address, bytes, target);
}

void chi_rn_dataless(void* handle, std::uint64_t address, std::uint32_t target) {
  vip::chi::RequestNode* node = Node(handle);
  if (node != nullptr) node->Dataless(address, target);
}

std::uint32_t chi_rn_completed(void* handle) {
  vip::chi::RequestNode* node = Node(handle);
  return node == nullptr ? 0 : static_cast<std::uint32_t>(node->stats().completed);
}

std::uint32_t chi_rn_mismatches(void* handle) {
  vip::chi::RequestNode* node = Node(handle);
  return node == nullptr ? 0 : static_cast<std::uint32_t>(node->stats().mismatches);
}

std::uint32_t chi_rn_unexpected(void* handle) {
  vip::chi::RequestNode* node = Node(handle);
  return node == nullptr ? 0 : static_cast<std::uint32_t>(node->stats().unexpected);
}

std::uint32_t chi_rn_outstanding(void* handle) {
  vip::chi::RequestNode* node = Node(handle);
  return node == nullptr ? 0 : static_cast<std::uint32_t>(node->Outstanding());
}

SvBit chi_rn_idle(void* handle) {
  vip::chi::RequestNode* node = Node(handle);
  return (node != nullptr && node->Idle()) ? 1 : 0;
}

// Reported here rather than returned as a count, because the useful thing about
// a byte in the wrong place is which byte and where -- and a testbench cannot
// print that from a number.
SvBit chi_rn_check_memory(void* handle, void* memory) {
  vip::chi::RequestNode* node = Node(handle);
  vip::MemoryBackend* backing = vip::MemoryFromHandle(memory);
  if (node == nullptr || backing == nullptr) return 0;

  auto log = vip::Logger("chi.dpi");
  unsigned wrong = 0;
  for (const auto& [address, want] : node->expectation()) {
    std::uint8_t got = 0;
    backing->Read(address, std::span<std::uint8_t>(&got, 1));
    if (got == want) continue;
    if (++wrong <= 8) {
      log->error("memory at {:#x} is {:#04x}, the requester wrote {:#04x}", address, got, want);
    }
  }
  if (wrong != 0) log->error("{} bytes are not what was written", wrong);
  return wrong == 0 ? 1 : 0;
}

void chi_rn_rx_rsp(void* handle, const SvBitVecVal* flit) {
  vip::chi::RequestNode* node = Node(handle);
  vip::chi::Rsp decoded{};
  if (node == nullptr || !vip::chi::Unpack(decoded, flit)) return;
  node->NextRsp(decoded);
}

void chi_rn_rx_dat(void* handle, const SvBitVecVal* flit) {
  vip::chi::RequestNode* node = Node(handle);
  vip::chi::Dat decoded{};
  if (node == nullptr || !vip::chi::Unpack(decoded, flit)) return;
  node->NextDat(decoded);
}

void chi_rn_rx_snp(void* handle, const SvBitVecVal* flit) {
  vip::chi::RequestNode* node = Node(handle);
  vip::chi::Snp decoded{};
  if (node == nullptr || !vip::chi::Unpack(decoded, flit)) return;
  node->NextSnp(decoded);
}

SvBit chi_rn_tx_req(void* handle, SvBitVecVal* flit) {
  vip::chi::RequestNode* node = Node(handle);
  vip::chi::Req next{};
  if (node == nullptr || !node->NextTxReq(&next)) return 0;
  return PackForSimulator(next, flit) ? 1 : 0;
}

SvBit chi_rn_tx_rsp(void* handle, SvBitVecVal* flit) {
  vip::chi::RequestNode* node = Node(handle);
  vip::chi::Rsp next{};
  if (node == nullptr || !node->NextTxRsp(&next)) return 0;
  return PackForSimulator(next, flit) ? 1 : 0;
}

SvBit chi_rn_tx_dat(void* handle, SvBitVecVal* flit) {
  vip::chi::RequestNode* node = Node(handle);
  vip::chi::Dat next{};
  if (node == nullptr || !node->NextTxDat(&next)) return 0;
  return PackForSimulator(next, flit) ? 1 : 0;
}

}  // extern "C"
