// Every (position, target) the reference layout can express, through both
// statements of the route function.
//
// Exhaustive rather than sampled: 16 x 16 x 2048 is half a million cases, the
// model is combinational, and this removes any argument about whether the
// interesting one was covered. It is also the whole of the correctness argument
// for routing -- if the RTL agrees with the model everywhere, then the
// properties nocgen's own tests prove about the model (minimal, terminating,
// dimension-ordered, no forbidden turn) hold of the RTL too.

#include <cstdint>
#include <cstdio>
#include <fstream>
#include <vector>

#include "Vchi_noc_route_dut.h"
#include "verilated.h"

namespace {

// Must match chi_noc_pkg and nocgen's NodeIdLayout. A disagreement shows up as
// a size mismatch on the table below rather than as a wrong answer.
constexpr int kXWidth = 4;
constexpr int kYWidth = 4;
constexpr int kPortWidth = 3;
constexpr int kNodeIdWidth = kXWidth + kYWidth + kPortWidth;

constexpr int kXs = 1 << kXWidth;
constexpr int kYs = 1 << kYWidth;
constexpr int kNodeIds = 1 << kNodeIdWidth;

std::vector<std::uint8_t> LoadTable(const char* path) {
  std::ifstream in(path, std::ios::binary);
  if (!in) {
    std::fprintf(stderr, "cannot open the route table at %s\n", path);
    std::exit(1);
  }
  return std::vector<std::uint8_t>((std::istreambuf_iterator<char>(in)),
                                   std::istreambuf_iterator<char>());
}

}  // namespace

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);

  if (argc < 2) {
    std::fprintf(stderr, "usage: %s <route_table.bin>\n", argv[0]);
    return 1;
  }
  const std::vector<std::uint8_t> expected = LoadTable(argv[1]);

  const std::size_t want = static_cast<std::size_t>(kXs) * kYs * kNodeIds;
  if (expected.size() != want) {
    std::fprintf(stderr,
                 "route table is %zu bytes, expected %zu -- chi_noc_pkg and "
                 "nocgen disagree about the NodeID layout\n",
                 expected.size(), want);
    return 1;
  }

  auto dut = std::make_unique<Vchi_noc_route_dut>();

  std::size_t index = 0;
  int failures = 0;
  for (int my_x = 0; my_x < kXs; ++my_x) {
    for (int my_y = 0; my_y < kYs; ++my_y) {
      for (int node_id = 0; node_id < kNodeIds; ++node_id, ++index) {
        dut->my_x_i = my_x;
        dut->my_y_i = my_y;
        dut->tgt_id_i = node_id;
        dut->eval();

        if (dut->dest_o != expected[index]) {
          if (++failures <= 10) {
            std::fprintf(stderr,
                         "at (%d,%d) target 0x%03x: RTL says 0x%02x, the model "
                         "says 0x%02x\n",
                         my_x, my_y, node_id, dut->dest_o, expected[index]);
          }
        }
      }
    }
  }

  dut->final();

  if (failures != 0) {
    std::fprintf(stderr, "%d of %zu route decisions disagree\n", failures, want);
    return 1;
  }
  std::printf("%zu route decisions agree with the model\n", want);
  return 0;
}
