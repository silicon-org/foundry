#include "hardware/vip/common/vip_dpi.h"

#include <cstdint>
#include <memory>
#include <vector>

#include "hardware/vip/common/logging.h"
#include "hardware/vip/common/test_control.h"

namespace {

// Memories live as long as the simulation does. A testbench creates them in an
// initial block and never destroys them, which is the right lifetime and not
// worth an ownership scheme to express.
std::vector<std::unique_ptr<vip::SparseMemory>>& Memories() {
  static std::vector<std::unique_ptr<vip::SparseMemory>> memories;
  return memories;
}

vip::SparseMemory* Memory(void* handle) { return static_cast<vip::SparseMemory*>(handle); }

}  // namespace

namespace vip {

MemoryBackend* MemoryFromHandle(void* handle) { return Memory(handle); }

}  // namespace vip

extern "C" {

void* vip_mem_create() {
  Memories().push_back(std::make_unique<vip::SparseMemory>());
  return Memories().back().get();
}

void vip_mem_load_word(void* handle, std::uint64_t address, std::uint32_t word) {
  const std::uint32_t words[] = {word};
  Memory(handle)->LoadWords(address, words);
}

// Ends the run when `address` is written, and fails it if what arrives is not
// `expected`. A watchpoint rather than a poll, so the run stops on the cycle the
// store lands and the log says what arrived rather than what was eventually
// found.
void vip_mem_expect_write(void* handle, std::uint64_t address, std::uint32_t expected) {
  Memory(handle)->Watch(address, 4,
                        [address, expected](std::uint64_t, std::span<const std::uint8_t> value) {
                          std::uint32_t written = 0;
                          for (unsigned i = 0; i < 4; ++i)
                            written |= static_cast<std::uint32_t>(value[i]) << (i * 8);
                          if (written != expected) {
                            vip::SetTestFailed(
                                fmt::format("{:#x} was written {:#x}, expected {:#x}", address,
                                            written, expected));
                            return;
                          }
                          vip::SetTestDone(
                              fmt::format("{:#x} was written {:#x}", address, written));
                        });
}

std::uint32_t vip_mem_read_word(void* handle, std::uint64_t address) {
  std::uint8_t bytes[4] = {};
  Memory(handle)->Read(address, bytes);
  std::uint32_t word = 0;
  for (unsigned i = 0; i < 4; ++i) word |= static_cast<std::uint32_t>(bytes[i]) << (i * 8);
  return word;
}

void vip_test_pass(const char* why) { vip::SetTestDone(why == nullptr ? "the testbench finished" : why); }

void vip_test_fail(const char* why) { vip::SetTestFailed(why == nullptr ? "the testbench failed" : why); }

unsigned char vip_test_done() { return vip::TestDone() ? 1 : 0; }

unsigned char vip_test_failed() { return vip::TestFailed() ? 1 : 0; }

}  // extern "C"
