// The evaluation loop every testbench in this repository shares.
//
// With `--timing`, time belongs to the SystemVerilog: the clock comes from a
// process in the testbench, reset comes from another, and the run ends when the
// testbench calls `$finish`. So there is nothing here for a test to configure,
// and nothing worth writing twice -- a testbench's C++ is one line calling this
// with its own model type.
//
// The loop is Verilator's documented one for a timing-enabled model. `eval()`
// runs whatever is scheduled now; `eventsPending()` asks whether anything is
// scheduled later; `nextTimeSlot()` says when. A model with no events left and
// no `$finish` has deadlocked, and saying so beats hanging in CI until the test
// timeout kills it with no explanation.

#ifndef HARDWARE_VIP_COMMON_SIM_MAIN_H_
#define HARDWARE_VIP_COMMON_SIM_MAIN_H_

#include <cstdint>
#include <cstdio>
#include <memory>

#include "verilated.h"

namespace vip {

// Runs a timing-enabled Verilated model to completion.
//
// Returns 0 if the testbench finished of its own accord, and non-zero if it
// deadlocked or if Verilator reported an error -- a failed assertion, for
// instance, which is how the SystemVerilog side fails a test.
template <typename Model>
int RunTimingModel(int argc, char** argv) {
  VerilatedContext context;
  context.commandArgs(argc, argv);

  // On the heap because these models are large -- a XiangShan cluster is tens
  // of megabytes of state -- and a stack that size is not portable.
  const auto model = std::make_unique<Model>(&context);

  while (!context.gotFinish()) {
    model->eval();

    // Before asking whether anything is scheduled later, because $finish leaves
    // nothing scheduled and a testbench that has just finished is not a
    // testbench that has deadlocked. Checking in the other order reports every
    // successful run as a hang, which is how this line came to be here.
    if (context.gotFinish()) break;

    if (!model->eventsPending()) {
      model->final();
      std::printf(
          "sim_main: no events left at time %llu and the testbench never "
          "called $finish -- the clock process stopped, or everything waiting "
          "on it did\n",
          static_cast<unsigned long long>(context.time()));
      return 1;
    }
    context.time(model->nextTimeSlot());
  }

  model->final();
  return context.gotError() ? 1 : 0;
}

}  // namespace vip

#endif  // HARDWARE_VIP_COMMON_SIM_MAIN_H_
