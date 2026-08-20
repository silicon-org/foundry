#include "hardware/vip/common/test_control.h"

#include "hardware/vip/common/logging.h"

namespace vip {
namespace {

bool done = false;
bool failed = false;
std::string verdict = "the testbench ended without a verdict";

}  // namespace

void SetTestDone(const std::string& why) {
  if (done) return;  // The first reason is the interesting one.
  done = true;
  verdict = why;
  Logger("vip")->info("done: {}", why);
}

void SetTestFailed(const std::string& why) {
  Logger("vip")->error("failed: {}", why);
  // Recorded even if something already declared the run done, because a failure
  // is not something a later success should be able to paper over.
  failed = true;
  if (!done) {
    done = true;
    verdict = why;
  }
}

bool TestDone() { return done; }
bool TestFailed() { return failed; }
const std::string& TestVerdict() { return verdict; }

}  // namespace vip
