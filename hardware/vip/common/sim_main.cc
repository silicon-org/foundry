// Verilator's legacy time hook.
//
// Its runtime references sc_time_stamp() whenever SystemC is not in play, and
// with --timing the value is never consulted: the model owns its own time. It
// exists so that every testbench here does not have to define it.

double sc_time_stamp() { return 0; }
