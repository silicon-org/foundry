// One named logger per agent.
//
// A protocol model produces a narrative -- this flit arrived, that transaction
// opened, this response went out -- and the difference between a debuggable run
// and a wall of text is being able to turn one agent up without turning
// everything else up with it. spdlog does that by name, and the name is the
// agent's own.
//
// Levels, and what belongs at each:
//
//   trace   every flit, in both directions
//   debug   every transaction: what opened it, what closed it
//   info    what a test would want in its log without being asked -- a
//           watchpoint firing, a program loaded
//   warn    something legal but surprising
//   error   a protocol violation
//
// The level comes from the environment rather than from a flag, so that
// re-running a failing test at trace does not mean recompiling anything:
//
//   VIP_LOG_LEVEL=trace bazel test --test_env=VIP_LOG_LEVEL ...

#ifndef HARDWARE_VIP_COMMON_LOGGING_H_
#define HARDWARE_VIP_COMMON_LOGGING_H_

#include <memory>
#include <string>

#include "spdlog/spdlog.h"

namespace vip {

// Returns the logger for `name`, creating it on first use. The level comes from
// VIP_LOG_LEVEL if set, and is `info` otherwise.
std::shared_ptr<spdlog::logger> Logger(const std::string& name);

}  // namespace vip

#endif  // HARDWARE_VIP_COMMON_LOGGING_H_
