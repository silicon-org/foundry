// The CHI home node, across the DPI boundary.
//
// One packed flit per call. The widths are literals because a DPI import
// declaration cannot be parameterised; chi_hn_agent.sv checks them against
// chi_pkg at time zero, and that check is an assertion rather than an
// elaboration-time $error because Verilator treats the latter as a warning.

`ifndef CHI_HN_DPI_SVH_
`define CHI_HN_DPI_SVH_

// Creates a home node over a memory from vip_mem_create, and registers it under
// `name` for a chi_hn_agent to find.
import "DPI-C" function chandle chi_hn_create(input string name, input int unsigned node_id,
                                              input int unsigned line_bytes,
                                              input chandle memory);

// The node created under this name, or null -- which the agent reports with the
// name it was looking for.
import "DPI-C" function chandle chi_hn_bind(input string name);

// What the node has served, so that a testbench can wait on it and assert
// against it rather than inferring it from a waveform.
import "DPI-C" function int unsigned chi_hn_reads(input chandle hn);
import "DPI-C" function int unsigned chi_hn_writes(input chandle hn);
import "DPI-C" function int unsigned chi_hn_unsupported(input chandle hn);
// Transactions opened and not yet retired; zero is what a finished run has.
import "DPI-C" function int unsigned chi_hn_outstanding(input chandle hn);

// Flits arriving from the request node.
import "DPI-C" function void chi_hn_rx_req(input chandle hn, input bit [161:0] flit);
import "DPI-C" function void chi_hn_rx_rsp(input chandle hn, input bit [72:0] flit);
import "DPI-C" function void chi_hn_rx_dat(input chandle hn, input bit [421:0] flit);

// Flits to send. Each returns 0 when there is nothing waiting, and removes what
// it returns -- so the agent asks only when the channel is free to take it.
import "DPI-C" function bit chi_hn_tx_rsp(input chandle hn, output bit [72:0] flit);
import "DPI-C" function bit chi_hn_tx_dat(input chandle hn, output bit [421:0] flit);
import "DPI-C" function bit chi_hn_tx_snp(input chandle hn, output bit [114:0] flit);

`endif  // CHI_HN_DPI_SVH_
