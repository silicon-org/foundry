// The memory a testbench sets up, and how a testbench knows it is finished.
//
// See hardware/vip/common/vip_dpi.h for why the setup is here rather than in a
// C++ main: a test is the SystemVerilog.
//
// Each testbench declares the imports it uses. Verilator emits a wrapper for
// every `import "DPI-C"` it parses, so a header of everything is an undefined
// symbol in whichever testbench implements less than all of it.

`ifndef VIP_DPI_SVH_
`define VIP_DPI_SVH_

// A memory that exists only where something has touched it. Untouched bytes read
// as 0xFF, which is an illegal RISC-V instruction in both encodings, so a core
// that fetches from memory nobody loaded traps at once.
import "DPI-C" function chandle vip_mem_create();

import "DPI-C" function void vip_mem_load_word(input chandle memory,
                                               input longint unsigned address,
                                               input int unsigned word);

// For a testbench checking what an agent actually wrote.
import "DPI-C" function int unsigned vip_mem_read_word(input chandle memory,
                                                       input longint unsigned address);

// Ends the run when `address` is written, and fails it if the value is not the
// one expected.
import "DPI-C" function void vip_mem_expect_write(input chandle memory,
                                                  input longint unsigned address,
                                                  input int unsigned expected);

// A testbench that reaches its own end says so. Without this, reaching $finish
// and reaching $finish having concluded anything look the same from a main(),
// and a testbench whose stimulus silently did nothing would pass.
import "DPI-C" function void vip_test_pass(input string why);

// Polled by the testbench, decided by whatever noticed first.
import "DPI-C" function bit vip_test_done();

`endif  // VIP_DPI_SVH_
