// What chi_layout_tb hands to C++ to judge. See chi_pkg_dpi.svh for why each
// testbench declares its own imports.

`ifndef CHI_LAYOUT_DPI_SVH_
`define CHI_LAYOUT_DPI_SVH_

`include "chi_test_channel.svh"

// One field of a flit the package built, by name, so that the C++ knows what to
// expect when it decodes the flit itself.
import "DPI-C" function void chi_report_field(input int channel, input string field,
                                              input longint value);

// The flit the package built, packed. Wider than any channel needs; the C++
// reads only the bits the channel has.
import "DPI-C" function void chi_check_flit(input int channel, input bit [511:0] flit);

`endif  // CHI_LAYOUT_DPI_SVH_
