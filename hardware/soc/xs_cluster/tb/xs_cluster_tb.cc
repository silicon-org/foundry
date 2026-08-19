// The XiangShan cluster testbench.
//
// Everything this test does is in xs_cluster_tb.sv -- the program, the memory it
// runs out of, the home node that serves it and the address whose being written
// ends the run. This file exists because a Verilated model needs a main(), and
// the loop that drives a timing-enabled one is the same for every testbench.

#include "Vxs_cluster_tb.h"
#include "hardware/vip/common/sim_main.h"

int main(int argc, char** argv) { return vip::RunTimingModel<Vxs_cluster_tb>(argc, argv); }
