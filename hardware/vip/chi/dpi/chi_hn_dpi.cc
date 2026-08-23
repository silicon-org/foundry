#include "hardware/vip/chi/dpi/chi_hn_dpi.h"

#include <cstdint>
#include <map>
#include <memory>
#include <string>

#include "hardware/vip/common/logging.h"
#include "hardware/vip/common/vip_dpi.h"

// svdpi.h is not included, and the two typedefs it would supply are written out
// instead. rules_verilator builds the Verilated runtime under a configuration
// transition -- one for timing-enabled models, one for the rest -- so a library
// that named the target the header comes from would pull the wrong copy into
// half the testbenches here. The types are part of the DPI ABI and do not
// change: svBitVecVal is uint32_t and svBit is unsigned char.
using SvBitVecVal = std::uint32_t;
using SvBit = unsigned char;

namespace {

// Home nodes live as long as the simulation does, like the memories behind
// them. A testbench creates one in an initial block and never destroys it.
std::map<std::string, std::unique_ptr<vip::chi::HomeNode>>& Registry() {
  static std::map<std::string, std::unique_ptr<vip::chi::HomeNode>> registry;
  return registry;
}

// A chandle is a void* and what it points at is the node itself, so there is no
// wrapper object to own or to leak.
vip::chi::HomeNode* Node(void* handle) {
  if (handle == nullptr) return nullptr;
  return static_cast<vip::chi::HomeNode*>(handle);
}

// Copies a flit into a buffer of the size CHIron's writer wants, which is one
// word longer than the flit: a field ending on a word boundary spills into the
// next word, and the simulator only ever hands over ceil(WIDTH / 32).
template <typename Flit>
bool PackForSimulator(const Flit& flit, SvBitVecVal* into) {
  std::uint32_t buffer[vip::chi::kWordsFor<Flit>] = {};
  if (!vip::chi::Pack(flit, buffer)) return false;
  for (std::size_t word = 0; word < (Flit::WIDTH + 31) / 32; ++word) into[word] = buffer[word];
  return true;
}

}  // namespace

namespace vip::chi {

HomeNode* HomeNodeNamed(const std::string& name) {
  const auto it = Registry().find(name);
  return it == Registry().end() ? nullptr : it->second.get();
}

}  // namespace vip::chi

extern "C" {

void* chi_hn_create(const char* name, std::uint32_t node_id, std::uint32_t line_bytes,
                    void* memory) {
  const std::string key = name == nullptr ? "" : name;
  vip::MemoryBackend* backing = vip::MemoryFromHandle(memory);
  if (backing == nullptr) {
    vip::Logger("chi.dpi")->error("chi_hn_create('{}') was given no memory", key);
    return nullptr;
  }
  auto node = std::make_unique<vip::chi::HomeNode>(
      vip::chi::HomeNode::Config{node_id, key, line_bytes}, *backing);
  vip::chi::HomeNode* raw = node.get();
  Registry()[key] = std::move(node);
  return raw;
}

// Separate from creating it, because the testbench creates and the agent module
// finds. Returning null rather than failing here lets the agent say which name
// it was looking for, which is more use than a stack trace out of a DPI call.
void* chi_hn_bind(const char* name) {
  const std::string key = name == nullptr ? "" : name;
  return vip::chi::HomeNodeNamed(key);
}

// Counters a testbench can wait on and assert against, so that "the home node
// served the line the core asked for" is a fact the SystemVerilog can state.
std::uint32_t chi_hn_reads(void* handle) {
  vip::chi::HomeNode* node = Node(handle);
  return node == nullptr ? 0 : static_cast<std::uint32_t>(node->stats().reads);
}

std::uint32_t chi_hn_writes(void* handle) {
  vip::chi::HomeNode* node = Node(handle);
  return node == nullptr ? 0 : static_cast<std::uint32_t>(node->stats().writes);
}

// Transactions opened and not yet retired. A run that ends with any of these
// ended in the middle of something, and no other counter says so.
std::uint32_t chi_hn_outstanding(void* handle) {
  vip::chi::HomeNode* node = Node(handle);
  return node == nullptr ? 0 : static_cast<std::uint32_t>(node->Outstanding());
}

std::uint32_t chi_hn_unsupported(void* handle) {
  vip::chi::HomeNode* node = Node(handle);
  return node == nullptr ? 0 : static_cast<std::uint32_t>(node->stats().unsupported);
}

void chi_hn_rx_req(void* handle, const SvBitVecVal* flit) {
  vip::chi::HomeNode* node = Node(handle);
  vip::chi::Req decoded{};
  if (node == nullptr || !vip::chi::Unpack(decoded, flit)) return;
  node->NextReq(decoded);
}

void chi_hn_rx_rsp(void* handle, const SvBitVecVal* flit) {
  vip::chi::HomeNode* node = Node(handle);
  vip::chi::Rsp decoded{};
  if (node == nullptr || !vip::chi::Unpack(decoded, flit)) return;
  node->NextRsp(decoded);
}

void chi_hn_rx_dat(void* handle, const SvBitVecVal* flit) {
  vip::chi::HomeNode* node = Node(handle);
  vip::chi::Dat decoded{};
  if (node == nullptr || !vip::chi::Unpack(decoded, flit)) return;
  node->NextDat(decoded);
}

// Each of these removes what it returns from the node's queue, so a caller that
// asks has undertaken to send. The testbench only asks when the channel it
// would go out on is free.
SvBit chi_hn_tx_rsp(void* handle, SvBitVecVal* flit) {
  vip::chi::HomeNode* node = Node(handle);
  vip::chi::Rsp next{};
  if (node == nullptr || !node->NextTxRsp(&next)) return 0;
  return PackForSimulator(next, flit) ? 1 : 0;
}

SvBit chi_hn_tx_dat(void* handle, SvBitVecVal* flit) {
  vip::chi::HomeNode* node = Node(handle);
  vip::chi::Dat next{};
  if (node == nullptr || !node->NextTxDat(&next)) return 0;
  return PackForSimulator(next, flit) ? 1 : 0;
}

SvBit chi_hn_tx_snp(void* handle, SvBitVecVal* flit) {
  vip::chi::HomeNode* node = Node(handle);
  vip::chi::Snp next{};
  if (node == nullptr || !node->NextTxSnp(&next)) return 0;
  return PackForSimulator(next, flit) ? 1 : 0;
}

}  // extern "C"
