// The XiangShan cluster testbench.
//
// Everything the test does is in xs_cluster_tb.sv; this exists because a
// Verilated model needs a main(), and the loop that drives a timing-enabled one
// is the same for every testbench here.

#include "Vxs_cluster_tb.h"
#include "hardware/vip/common/sim_main.h"

int main(int argc, char** argv) { return vip::RunTimingModel<Vxs_cluster_tb>(argc, argv); }
