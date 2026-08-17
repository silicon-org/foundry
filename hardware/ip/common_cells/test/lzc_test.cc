// Exhaustive check of cc_lzc at Width=8.
//
// The design is purely combinational, so "exhaustive" is 256 inputs and takes
// no measurable time. Where that is affordable it beats sampling: there is no
// argument afterwards about whether the interesting case was covered.
//
// Expected values are computed independently here rather than captured from the
// DUT. A test that asserts whatever the design already does cannot fail.

#include <cstdint>
#include <cstdio>

#include "Vlzc_tb.h"
#include "verilated.h"

namespace {

constexpr int kWidth = 8;

// Number of zeros below the lowest set bit.
int ExpectedTrailing(uint32_t value) {
  for (int i = 0; i < kWidth; ++i) {
    if (value & (1u << i)) return i;
  }
  return 0;  // Undefined for zero; empty_o flags it instead.
}

// Number of zeros above the highest set bit.
int ExpectedLeading(uint32_t value) {
  for (int i = kWidth - 1; i >= 0; --i) {
    if (value & (1u << i)) return kWidth - 1 - i;
  }
  return 0;
}

int failures = 0;

void Check(const char* what, uint32_t input, int expected, int actual) {
  if (expected == actual) return;
  std::printf("FAIL %s(0x%02x): expected %d, got %d\n", what, input, expected,
              actual);
  ++failures;
}

}  // namespace

// Verilator's legacy time hook, referenced by its runtime whenever SystemC is
// not in play. This design is purely combinational, so time never advances and
// the value is never consulted -- it exists to satisfy the linker.
double sc_time_stamp() { return 0; }

int main(int argc, char** argv) {
  VerilatedContext context;
  context.commandArgs(argc, argv);
  Vlzc_tb dut{&context};

  for (uint32_t value = 0; value < (1u << kWidth); ++value) {
    dut.in_i = value;
    dut.eval();

    const bool empty = value == 0;
    Check("trailing_empty", value, empty, dut.trailing_empty_o);
    Check("leading_empty", value, empty, dut.leading_empty_o);

    // cnt_o carries no meaning when the input is all zeros; empty_o is the
    // signal that says so, and it is checked above.
    if (!empty) {
      Check("trailing_cnt", value, ExpectedTrailing(value), dut.trailing_cnt_o);
      Check("leading_cnt", value, ExpectedLeading(value), dut.leading_cnt_o);
    }
  }

  dut.final();

  if (failures != 0) {
    std::printf("%d failures across %d input vectors\n", failures, 1 << kWidth);
    return 1;
  }
  std::printf("cc_lzc: all %d input vectors correct in both modes\n",
              1 << kWidth);
  return 0;
}
