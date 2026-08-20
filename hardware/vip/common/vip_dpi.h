// The memory a testbench sets up, from the testbench.
//
// A test is the SystemVerilog: the program it loads, the address it waits on and
// the value it expects belong in one file with the clock and the design, not
// split between that file and a C++ main nobody looks at twice. So the memory is
// created, filled and watched over DPI, and a testbench needs no C++ of its own
// at all -- Verilator's `--main` generates the evaluation loop, and the verdict
// crosses back through vip_test_done/vip_test_failed.

#ifndef HARDWARE_VIP_COMMON_VIP_DPI_H_
#define HARDWARE_VIP_COMMON_VIP_DPI_H_

#include "hardware/vip/common/memory.h"

namespace vip {

// The memory behind a chandle handed out by vip_mem_create.
MemoryBackend* MemoryFromHandle(void* handle);

}  // namespace vip

#endif  // HARDWARE_VIP_COMMON_VIP_DPI_H_
