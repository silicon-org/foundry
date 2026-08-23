// The fabric's own structure: which port is which, how a NodeID is laid out,
// and where a flit goes next.
//
// Nothing here knows anything about CHI. That is deliberate and it is what makes
// `chi_xp_channel` -- the largest and most intricate module in the fabric --
// compilable and testable with no CHI package in the build at all. The flits a
// crosspoint carries are described one file over, in chi_noc_flit_pkg, which is
// where the CHI issue enters and the only place it does.
package chi_noc_pkg;

  ////////////////////////////////////////////////////////////////////////////////////////////////
  // Ports
  //
  // Four compass directions and two device ports, in the order the RTL indexes
  // them and the generator emits them. OpenNoC numbers its crosspoint the same
  // way; //hardware/ip/chi_noc/nocgen/routing.py pins these values in a test,
  // because a reordering here silently rewires every generated mesh.
  ////////////////////////////////////////////////////////////////////////////////////////////////

  localparam int unsigned CHI_XP_PORTS = 6;

  localparam int unsigned CHI_XP_EAST = 0;
  localparam int unsigned CHI_XP_WEST = 1;
  localparam int unsigned CHI_XP_NORTH = 2;
  localparam int unsigned CHI_XP_SOUTH = 3;
  localparam int unsigned CHI_XP_P0 = 4;
  localparam int unsigned CHI_XP_P1 = 5;

  localparam int unsigned CHI_XP_DEVICE_PORTS = CHI_XP_PORTS - CHI_XP_P0;

  typedef logic [CHI_XP_PORTS-1:0] chi_xp_port_mask_t;

  function automatic logic chi_xp_is_vertical(int unsigned port);
    return (port == CHI_XP_NORTH) || (port == CHI_XP_SOUTH);
  endfunction

  function automatic logic chi_xp_is_horizontal(int unsigned port);
    return (port == CHI_XP_EAST) || (port == CHI_XP_WEST);
  endfunction

  function automatic logic chi_xp_is_device(int unsigned port);
    return port >= CHI_XP_P0;
  endfunction

  // Whether a flit arriving on `in_port` may leave by `out_port`.
  //
  // Two rules, and between them they are the deadlock argument. A flit that came
  // in through North or South has had its X resolved already -- dimension-order
  // routing finishes X before it starts Y -- so it may never turn back onto an X
  // link. Four of the thirty-six pairs therefore do not exist, the channel
  // dependency graph has no cycle, and the fabric cannot deadlock within a class.
  //
  // Leaving by the port it arrived on is the other: that is a node addressing
  // itself, or two nodes sharing a NodeID.
  //
  // `chi_xp_channel` asserts on both, //hardware/ip/chi_noc/test drives each of
  // them to watch the assertion fire, and M5 requires the coverage bins for the
  // forbidden turns to stay *empty* -- a turn that is illegal and never taken
  // and a turn that is illegal and quietly taken look identical in a report that
  // only counts what happened.
  function automatic logic chi_xp_turn_legal(int unsigned in_port, int unsigned out_port);
    if (in_port == out_port) return 1'b0;
    if (chi_xp_is_vertical(in_port) && chi_xp_is_horizontal(out_port)) return 1'b0;
    return 1'b1;
  endfunction

  ////////////////////////////////////////////////////////////////////////////////////////////////
  // NodeID
  //
  // X above Y above the port index, which is CMN's convention. 4/4/3 fills the
  // eleven bits chi_pkg's reference link declares with nothing wasted, and is
  // what nocgen emits by default -- the two have to agree, and
  // //hardware/ip/chi_noc/test is where that is checked rather than assumed.
  ////////////////////////////////////////////////////////////////////////////////////////////////

  localparam int unsigned CHI_NOC_X_WIDTH = 4;
  localparam int unsigned CHI_NOC_Y_WIDTH = 4;
  localparam int unsigned CHI_NOC_PORT_WIDTH = 3;
  localparam int unsigned CHI_NOC_NODEID_WIDTH =
      CHI_NOC_X_WIDTH + CHI_NOC_Y_WIDTH + CHI_NOC_PORT_WIDTH;

  typedef logic [CHI_NOC_X_WIDTH-1:0] chi_noc_x_t;
  typedef logic [CHI_NOC_Y_WIDTH-1:0] chi_noc_y_t;
  typedef logic [CHI_NOC_PORT_WIDTH-1:0] chi_noc_dev_t;
  typedef logic [CHI_NOC_NODEID_WIDTH-1:0] chi_noc_nodeid_t;

  function automatic chi_noc_x_t chi_noc_node_x(chi_noc_nodeid_t node_id);
    return node_id[CHI_NOC_NODEID_WIDTH-1-:CHI_NOC_X_WIDTH];
  endfunction

  function automatic chi_noc_y_t chi_noc_node_y(chi_noc_nodeid_t node_id);
    return node_id[CHI_NOC_PORT_WIDTH+:CHI_NOC_Y_WIDTH];
  endfunction

  function automatic chi_noc_dev_t chi_noc_node_port(chi_noc_nodeid_t node_id);
    return node_id[CHI_NOC_PORT_WIDTH-1:0];
  endfunction

  function automatic chi_noc_nodeid_t chi_noc_node_id(chi_noc_x_t x, chi_noc_y_t y,
                                                      chi_noc_dev_t port);
    return {x, y, port};
  endfunction

  ////////////////////////////////////////////////////////////////////////////////////////////////
  // Routing
  ////////////////////////////////////////////////////////////////////////////////////////////////

  // The port a flit at (my_x, my_y) leaves by, one-hot.
  //
  // Dimension-ordered, X then Y, which is minimal and -- because X is fully
  // resolved before any Y hop -- acyclic. Total by construction: a crosspoint
  // cannot refuse a flit, and dropping one silently is the failure mode this
  // whole fabric exists not to have, so every input has an answer.
  //
  // The reference statement of this function is
  // //hardware/ip/chi_noc/nocgen/routing.py, and //hardware/ip/chi_noc/test
  // walks every (position, target) pair through both and requires them to
  // agree. Two statements of one function is the point: neither was written
  // from the other.
  function automatic chi_xp_port_mask_t chi_xp_route(chi_noc_x_t my_x, chi_noc_y_t my_y,
                                                     chi_noc_nodeid_t tgt_id);
    chi_noc_x_t tgt_x = chi_noc_node_x(tgt_id);
    chi_noc_y_t tgt_y = chi_noc_node_y(tgt_id);
    chi_noc_dev_t tgt_port = chi_noc_node_port(tgt_id);

    if (tgt_x > my_x) return chi_xp_port_mask_t'(1) << CHI_XP_EAST;
    if (tgt_x < my_x) return chi_xp_port_mask_t'(1) << CHI_XP_WEST;
    if (tgt_y > my_y) return chi_xp_port_mask_t'(1) << CHI_XP_NORTH;
    if (tgt_y < my_y) return chi_xp_port_mask_t'(1) << CHI_XP_SOUTH;
    return chi_xp_port_mask_t'(1) << (CHI_XP_P0 + 32'(tgt_port));
  endfunction

endpackage : chi_noc_pkg
