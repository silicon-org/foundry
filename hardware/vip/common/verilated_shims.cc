// Verilator's legacy time hook, which its runtime references but --timing never
// consults. Here so that every testbench does not have to define it.
//
// -DVL_TIME_CONTEXT would remove the reference, but --main only puts it in the
// makefile Verilator writes for itself, which rules_verilator does not use.

double sc_time_stamp() { return 0; }
