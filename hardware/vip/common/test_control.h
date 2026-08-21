// How a C++ model ends a SystemVerilog simulation.
//
// With --timing the testbench owns time, so it is the testbench that calls
// $finish -- but what the run was waiting for is usually a fact the C++ side
// knows first: a watchpoint fired, a scoreboard found a mismatch. This is the
// one bit of state that crosses back, and keeping it protocol-agnostic means a
// CHI test and an AXI test end the same way.

#ifndef HARDWARE_VIP_COMMON_TEST_CONTROL_H_
#define HARDWARE_VIP_COMMON_TEST_CONTROL_H_

#include <string>

namespace vip {

// The run has reached its end. The testbench polls this and calls $finish.
void SetTestDone(const std::string& why);
bool TestDone();

// The run has reached its end and the answer was wrong. Also sets done: there
// is nothing to be gained by continuing, and a failure that lets the simulation
// run on buries itself in whatever happens next.
void SetTestFailed(const std::string& why);
bool TestFailed();

// Why, for the log line at the end.
const std::string& TestVerdict();

}  // namespace vip

#endif  // HARDWARE_VIP_COMMON_TEST_CONTROL_H_
