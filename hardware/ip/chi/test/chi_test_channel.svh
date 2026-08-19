// Channel identifiers shared by the tests and their C++ halves.
//
// A plain int rather than an enum, because it crosses DPI and the C++ side
// declares the matching values itself.

`ifndef CHI_TEST_CHANNEL_SVH_
`define CHI_TEST_CHANNEL_SVH_

`define CHI_CH_REQ 0
`define CHI_CH_RSP 1
`define CHI_CH_DAT 2
`define CHI_CH_SNP 3

`endif  // CHI_TEST_CHANNEL_SVH_
