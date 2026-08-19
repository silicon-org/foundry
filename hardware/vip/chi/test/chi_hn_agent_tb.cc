// The CHI agent testbench. Everything it does is in chi_hn_agent_tb.sv; this
// exists because a Verilated model needs a main().

#include "Vchi_hn_agent_tb.h"
#include "hardware/vip/common/sim_main.h"

int main(int argc, char** argv) { return vip::RunTimingModel<Vchi_hn_agent_tb>(argc, argv); }
