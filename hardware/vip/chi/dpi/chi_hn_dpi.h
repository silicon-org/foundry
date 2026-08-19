// The CHI home node, across the DPI boundary.
//
// One packed flit per call, in or out, and a chandle per agent. That is the
// whole contract: the SystemVerilog link layer knows how to move flits and
// nothing about what is in them, and the C++ home node knows what they mean and
// nothing about wires. Neither includes a header from the other.
//
// The node is created by the testbench, over a memory the testbench also
// created, so that the whole test -- the program, the address it waits on, the
// node that serves it -- reads as one file. See
// hardware/vip/common/vip_dpi.h.
//
// This header exists for the tests that drive the node directly, with no
// simulator in the build; nothing in a testbench needs it.

#ifndef HARDWARE_VIP_CHI_DPI_CHI_HN_DPI_H_
#define HARDWARE_VIP_CHI_DPI_CHI_HN_DPI_H_

#include <string>

#include "hardware/vip/chi/chi_home_node.h"

namespace vip::chi {

// The node a testbench created under `name`, or null.
HomeNode* HomeNodeNamed(const std::string& name);

}  // namespace vip::chi

#endif  // HARDWARE_VIP_CHI_DPI_CHI_HN_DPI_H_
