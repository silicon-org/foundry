// The CHI link loopback testbench. Everything it does is in
// chi_link_loopback_tb.sv; this exists because a Verilated model needs a main().

#include "Vchi_link_loopback_tb.h"
#include "hardware/vip/common/sim_main.h"

int main(int argc, char** argv) {
  return vip::RunTimingModel<Vchi_link_loopback_tb>(argc, argv);
}
