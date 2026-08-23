// The CHI request node, across the DPI boundary.
//
// The mirror of chi_hn_dpi.h and the same contract: one packed flit per call, a
// chandle per agent, and neither side including a header from the other.
//
// A request node is created and given its work by the test's own main(), before
// the first clock edge, so that what a run is meant to do reads as one file.
// This header exists for tests that drive the node directly with no simulator;
// nothing in a testbench needs it.

#ifndef HARDWARE_VIP_CHI_DPI_CHI_RN_DPI_H_
#define HARDWARE_VIP_CHI_DPI_CHI_RN_DPI_H_

#include <string>

#include "hardware/vip/chi/chi_request_node.h"

namespace vip::chi {

// The node a testbench created under `name`, or null.
RequestNode* RequestNodeNamed(const std::string& name);

}  // namespace vip::chi

#endif  // HARDWARE_VIP_CHI_DPI_CHI_RN_DPI_H_
