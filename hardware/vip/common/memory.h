// A backing store for the verification agents, and the protocol-agnostic parts
// of watching one.
//
// Every agent needs somewhere to put the bytes a transaction moves, and none of
// them needs a different one. A CHI home node, an AXI subordinate and a TileLink
// slave differ in how a request arrives and what may be said in reply; by the
// time there is an address, a length and a byte enable, they are the same
// problem. Keeping that here is what makes //hardware/vip/README.md's claim
// about the layering checkable: if a second protocol needs this file changed,
// the layering was wrong.

#ifndef HARDWARE_VIP_COMMON_MEMORY_H_
#define HARDWARE_VIP_COMMON_MEMORY_H_

#include <cstddef>
#include <cstdint>
#include <functional>
#include <map>
#include <memory>
#include <span>
#include <string>
#include <vector>

namespace vip {

// What an agent writes into and reads out of.
class MemoryBackend {
 public:
  virtual ~MemoryBackend() = default;

  virtual void Read(std::uint64_t address, std::span<std::uint8_t> into) = 0;

  // `enable` holds one byte per data byte, zero meaning leave that byte alone.
  // An empty span means every byte is written, which is the common case and
  // saves the caller building a run of ones.
  virtual void Write(std::uint64_t address, std::span<const std::uint8_t> from,
                     std::span<const std::uint8_t> enable) = 0;

  void Write(std::uint64_t address, std::span<const std::uint8_t> from) {
    Write(address, from, {});
  }
};

// Called after a write that overlaps a watched range, with the address and the
// bytes as they now stand in memory.
using WriteObserver =
    std::function<void(std::uint64_t address, std::span<const std::uint8_t> value)>;

// A memory that exists only where something has touched it.
//
// The address space is 48 bits and a test uses a few pages of it, so pages are
// allocated on first touch. Untouched bytes read as 0xFF, which is not an
// arbitrary choice: an all-ones word is an illegal RISC-V instruction, in both
// the 32-bit and the compressed encodings, so a core that fetches from memory
// nobody loaded traps at once instead of executing whatever the pattern happened
// to encode.
class SparseMemory : public MemoryBackend {
 public:
  static constexpr std::size_t kPageBytes = 4096;
  static constexpr std::uint8_t kUntouched = 0xFF;

  // Brings the two-argument Write along. Overriding the three-argument one
  // hides it otherwise, which is a C++ rule rather than an intention.
  using MemoryBackend::Write;

  void Read(std::uint64_t address, std::span<std::uint8_t> into) override;
  void Write(std::uint64_t address, std::span<const std::uint8_t> from,
             std::span<const std::uint8_t> enable) override;

  // Loads a program. Words rather than bytes because that is how instructions
  // are written down, and little-endian because that is what RISC-V is.
  void LoadWords(std::uint64_t address, std::span<const std::uint32_t> words);

  // Fires after any write that touches [address, address + bytes). The
  // observer sees the range as a whole, not the part the write covered, so a
  // test looking at a 64-bit flag gets a 64-bit value however it was stored.
  void Watch(std::uint64_t address, std::size_t bytes, WriteObserver observer);

  // Pages allocated so far. A test that expects to touch three pages and
  // touches thirty has a bug in its addressing, and this is how it finds out.
  std::size_t PagesTouched() const { return pages_.size(); }

 private:
  struct Watchpoint {
    std::uint64_t address;
    std::size_t bytes;
    WriteObserver observer;
  };

  std::vector<std::uint8_t>& PageFor(std::uint64_t address);
  void NotifyWatchers(std::uint64_t address, std::size_t bytes);

  std::map<std::uint64_t, std::vector<std::uint8_t>> pages_;
  std::vector<Watchpoint> watchpoints_;
};

}  // namespace vip

#endif  // HARDWARE_VIP_COMMON_MEMORY_H_
