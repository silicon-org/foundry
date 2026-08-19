// SparseMemory, and the watchpoints on it.
//
// Small, cheap, and worth having before anything is built on top: a home node
// that returns the wrong bytes because a page boundary was mishandled looks
// exactly like a coherence bug, and this is where that gets ruled out.

#include "hardware/vip/common/memory.h"

#include <cstdint>
#include <cstdio>
#include <span>
#include <vector>

namespace {

int failures = 0;

void Fail(const char* what) {
  std::printf("FAIL %s\n", what);
  ++failures;
}

void ExpectBytes(const char* what, std::span<const std::uint8_t> got,
                 std::span<const std::uint8_t> want) {
  if (got.size() != want.size()) {
    Fail(what);
    std::printf("  %zu bytes, expected %zu\n", got.size(), want.size());
    return;
  }
  for (std::size_t i = 0; i < got.size(); ++i) {
    if (got[i] == want[i]) continue;
    Fail(what);
    std::printf("  byte %zu is 0x%02x, expected 0x%02x\n", i, got[i], want[i]);
    return;
  }
}

// Memory nobody has written reads as all ones, which is an illegal RISC-V
// instruction in both encodings. A core that fetches from it should trap rather
// than run whatever the fill pattern happened to encode.
void UntouchedIsAllOnes() {
  vip::SparseMemory memory;
  std::vector<std::uint8_t> got(8);
  memory.Read(0x8000'0000, got);
  ExpectBytes("untouched", got, std::vector<std::uint8_t>(8, 0xFF));
}

void ReadsWhatWasWritten() {
  vip::SparseMemory memory;
  const std::vector<std::uint8_t> written = {1, 2, 3, 4, 5, 6, 7, 8};
  memory.Write(0x1000, written);

  std::vector<std::uint8_t> got(written.size());
  memory.Read(0x1000, got);
  ExpectBytes("round trip", got, written);
}

// Byte enables are how a partial write reaches memory, and getting them
// backwards writes exactly the bytes that should have been left alone.
void ByteEnablesSkipBytes() {
  vip::SparseMemory memory;
  memory.Write(0x2000, std::vector<std::uint8_t>{0x11, 0x22, 0x33, 0x44});

  const std::vector<std::uint8_t> update = {0xAA, 0xBB, 0xCC, 0xDD};
  const std::vector<std::uint8_t> enable = {1, 0, 1, 0};
  memory.Write(0x2000, update, enable);

  std::vector<std::uint8_t> got(4);
  memory.Read(0x2000, got);
  ExpectBytes("byte enables", got, std::vector<std::uint8_t>{0xAA, 0x22, 0xCC, 0x44});
}

// A cache line does not straddle a page, but an MMIO burst can, and a memory
// that assumes one page per access silently drops the second half.
void CrossesPageBoundaries() {
  vip::SparseMemory memory;
  const std::uint64_t across = vip::SparseMemory::kPageBytes - 2;

  const std::vector<std::uint8_t> written = {0xDE, 0xAD, 0xBE, 0xEF};
  memory.Write(across, written);

  std::vector<std::uint8_t> got(written.size());
  memory.Read(across, got);
  ExpectBytes("across a page boundary", got, written);

  if (memory.PagesTouched() != 2) {
    Fail("across a page boundary");
    std::printf("  touched %zu pages, expected 2\n", memory.PagesTouched());
  }
}

// Instructions are written down as words, and RISC-V is little-endian. Getting
// this backwards produces a program that is wrong in a way no memory test would
// otherwise notice.
void WordsAreLittleEndian() {
  vip::SparseMemory memory;
  const std::vector<std::uint32_t> program = {0x00000013, 0x0000006F};
  memory.LoadWords(0x8000'0000, program);

  std::vector<std::uint8_t> got(8);
  memory.Read(0x8000'0000, got);
  ExpectBytes("little-endian words", got,
              std::vector<std::uint8_t>{0x13, 0x00, 0x00, 0x00, 0x6F, 0x00, 0x00, 0x00});
}

// The watchpoint is what turns a store into a test's verdict, and it has to fire
// on the address it was given and on no other.
void WatchpointFiresOnItsOwnRange() {
  vip::SparseMemory memory;
  int fired = 0;
  std::uint64_t seen_at = 0;
  std::vector<std::uint8_t> seen_value;

  memory.Watch(0x8000'1000, 8, [&](std::uint64_t address, std::span<const std::uint8_t> value) {
    ++fired;
    seen_at = address;
    seen_value.assign(value.begin(), value.end());
  });

  memory.Write(0x8000'0FF8, std::vector<std::uint8_t>(8, 0x11));
  if (fired != 0) Fail("watchpoint fired on the range below it");

  memory.Write(0x8000'1008, std::vector<std::uint8_t>(8, 0x22));
  if (fired != 0) Fail("watchpoint fired on the range above it");

  memory.Write(0x8000'1004, std::vector<std::uint8_t>{0xAB, 0xCD, 0xEF, 0x01});
  if (fired != 1) {
    Fail("watchpoint");
    std::printf("  fired %d times on an overlapping write, expected 1\n", fired);
    return;
  }
  if (seen_at != 0x8000'1000) Fail("watchpoint reported the wrong address");

  // The observer sees the whole watched range, not the part the write covered,
  // so a test watching a 64-bit flag written a word at a time sees the flag.
  ExpectBytes("watchpoint value", seen_value,
              std::vector<std::uint8_t>{0xFF, 0xFF, 0xFF, 0xFF, 0xAB, 0xCD, 0xEF, 0x01});
}

}  // namespace

int main() {
  UntouchedIsAllOnes();
  ReadsWhatWasWritten();
  ByteEnablesSkipBytes();
  CrossesPageBoundaries();
  WordsAreLittleEndian();
  WatchpointFiresOnItsOwnRange();

  if (failures != 0) {
    std::printf("%d failures\n", failures);
    return 1;
  }
  std::printf("SparseMemory: pages, byte enables, endianness and watchpoints all as stated\n");
  return 0;
}
