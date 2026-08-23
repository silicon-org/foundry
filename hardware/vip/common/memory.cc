#include "hardware/vip/common/memory.h"

#include <algorithm>

namespace vip {

std::vector<std::uint8_t>& SparseMemory::PageFor(std::uint64_t address) {
  const std::uint64_t page = address / kPageBytes;
  auto it = pages_.find(page);
  if (it == pages_.end())
    it = pages_.emplace(page, std::vector<std::uint8_t>(kPageBytes, kUntouched)).first;
  return it->second;
}

void SparseMemory::Read(std::uint64_t address, std::span<std::uint8_t> into) {
  // A transfer may straddle a page boundary, so this walks pages rather than
  // assuming one. A cache line does not straddle; an unaligned MMIO access can.
  std::size_t done = 0;
  while (done < into.size()) {
    const std::uint64_t at = address + done;
    const std::size_t offset = at % kPageBytes;
    const std::size_t take = std::min(kPageBytes - offset, into.size() - done);
    const std::vector<std::uint8_t>& page = PageFor(at);
    std::copy_n(page.begin() + static_cast<std::ptrdiff_t>(offset), take,
                into.begin() + static_cast<std::ptrdiff_t>(done));
    done += take;
  }
}

void SparseMemory::Write(std::uint64_t address, std::span<const std::uint8_t> from,
                         std::span<const std::uint8_t> enable) {
  for (std::size_t i = 0; i < from.size(); ++i) {
    if (!enable.empty() && enable[i] == 0) continue;
    const std::uint64_t at = address + i;
    PageFor(at)[at % kPageBytes] = from[i];
  }
  NotifyWatchers(address, from.size());
}

void SparseMemory::LoadWords(std::uint64_t address, std::span<const std::uint32_t> words) {
  std::vector<std::uint8_t> bytes(words.size() * 4);
  for (std::size_t i = 0; i < words.size(); ++i) {
    bytes[i * 4 + 0] = static_cast<std::uint8_t>(words[i]);
    bytes[i * 4 + 1] = static_cast<std::uint8_t>(words[i] >> 8);
    bytes[i * 4 + 2] = static_cast<std::uint8_t>(words[i] >> 16);
    bytes[i * 4 + 3] = static_cast<std::uint8_t>(words[i] >> 24);
  }
  Write(address, bytes, {});
}

void SparseMemory::Watch(std::uint64_t address, std::size_t bytes, WriteObserver observer) {
  watchpoints_.push_back({address, bytes, std::move(observer)});
}

void SparseMemory::NotifyWatchers(std::uint64_t address, std::size_t bytes) {
  if (watchpoints_.empty()) return;
  for (const Watchpoint& watch : watchpoints_) {
    const bool overlaps = address < watch.address + watch.bytes && watch.address < address + bytes;
    if (!overlaps) continue;
    std::vector<std::uint8_t> value(watch.bytes);
    Read(watch.address, value);
    watch.observer(watch.address, value);
  }
}

}  // namespace vip
