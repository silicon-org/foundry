// The CHI request node, across the DPI boundary.
//
// One packed flit per call. The widths are literals because a DPI import
// declaration cannot be parameterised; chi_rn_core.sv checks them against
// chi_pkg at time zero, and that check is an assertion rather than an
// elaboration-time $error because Verilator treats the latter as a warning.

`ifndef CHI_RN_DPI_SVH_
`define CHI_RN_DPI_SVH_

// Creates a request node and registers it under `name` for a chi_rn_core to
// find. No memory: a request node has none, and what it believes memory holds
// is what it has written.
import "DPI-C" function chandle chi_rn_create(input string name, input int unsigned node_id,
                                              input int unsigned line_bytes,
                                              input int unsigned max_outstanding);

import "DPI-C" function chandle chi_rn_bind(input string name);

// Work, queued before the first clock edge or during a run. `target` is the
// home node that owns the address, which the System Address Map decides and
// this node is simply told.
import "DPI-C" function void chi_rn_read(input chandle rn, input longint unsigned address,
                                         input int unsigned bytes, input int unsigned target);
import "DPI-C" function void chi_rn_write(input chandle rn, input longint unsigned address,
                                          input int unsigned bytes, input int unsigned target);
import "DPI-C" function void chi_rn_dataless(input chandle rn, input longint unsigned address,
                                             input int unsigned target);

// What the node has done, so that a testbench can wait on it and assert against
// it. `mismatches` and `unexpected` are the verdict: the first says the fabric
// moved the wrong bytes, the second that it delivered something nobody asked
// for.
import "DPI-C" function int unsigned chi_rn_completed(input chandle rn);
import "DPI-C" function int unsigned chi_rn_mismatches(input chandle rn);
import "DPI-C" function int unsigned chi_rn_unexpected(input chandle rn);
import "DPI-C" function int unsigned chi_rn_outstanding(input chandle rn);
import "DPI-C" function bit chi_rn_idle(input chandle rn);

// Every byte this node wrote is in `memory` where it addressed it. The check
// that the bytes went where they were sent rather than merely somewhere.
import "DPI-C" function bit chi_rn_check_memory(input chandle rn, input chandle memory);

// Flits arriving from the fabric.
import "DPI-C" function void chi_rn_rx_rsp(input chandle rn, input bit [72:0] flit);
import "DPI-C" function void chi_rn_rx_dat(input chandle rn, input bit [421:0] flit);
import "DPI-C" function void chi_rn_rx_snp(input chandle rn, input bit [114:0] flit);

// Flits to send. Each returns 0 when there is nothing waiting, and removes what
// it returns -- so the agent asks only when the channel is free to take it.
import "DPI-C" function bit chi_rn_tx_req(input chandle rn, output bit [161:0] flit);
import "DPI-C" function bit chi_rn_tx_rsp(input chandle rn, output bit [72:0] flit);
import "DPI-C" function bit chi_rn_tx_dat(input chandle rn, output bit [421:0] flit);

`endif  // CHI_RN_DPI_SVH_
