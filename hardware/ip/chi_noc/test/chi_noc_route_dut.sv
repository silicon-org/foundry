// The route function, given pins so a test can sweep it.
//
// `chi_xp_route` is a function, and a function is not something Verilator can
// elaborate on its own. This is the smallest module that exposes it: no state,
// no clock, and every input reachable from the testbench -- the same shape
// //hardware/ip/common_cells/test uses for cc_lzc, and for the same reason.
// Correctness here is a truth table, not a waveform.
module chi_noc_route_dut (
    input  chi_noc_pkg::chi_noc_x_t      my_x_i,
    input  chi_noc_pkg::chi_noc_y_t      my_y_i,
    input  chi_noc_pkg::chi_noc_nodeid_t tgt_id_i,
    output logic [chi_noc_pkg::CHI_XP_PORTS-1:0] dest_o
);

  assign dest_o = chi_noc_pkg::chi_xp_route(my_x_i, my_y_i, tgt_id_i);

endmodule
