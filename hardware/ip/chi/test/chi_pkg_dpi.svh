// What chi_pkg_tb hands to C++ to judge.
//
// SystemVerilog drives, C++ decides. The alternative -- $error in the
// testbench -- has no failure count Verilator exposes to a main(), so the
// verdict would have to be scraped from stderr.
//
// Each testbench declares only the imports it implements: Verilator emits a
// wrapper for every `import "DPI-C"` it sees, and an unimplemented one is a
// link error rather than dead code.

`ifndef CHI_PKG_DPI_SVH_
`define CHI_PKG_DPI_SVH_

`include "chi_test_channel.svh"

// One integer the package computed against what it should be.
import "DPI-C" function void chi_expect(input string what, input longint got, input longint want);

// The width of a channel's flit type, against CHIron's independently computed
// one. This is the assertion the whole package exists to satisfy.
import "DPI-C" function void chi_expect_flit_width(input int channel, input int width);

// One encoding of one opcode space, by the name the package gives it, or "" if
// the package defines nothing at that value. C++ compares against CHIron.
import "DPI-C" function void chi_check_opcode(input int channel, input int opcode,
                                              input string name);

`endif  // CHI_PKG_DPI_SVH_
