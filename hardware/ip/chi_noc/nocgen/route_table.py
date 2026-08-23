"""The routing model, serialised, so RTL can be checked against it.

`routing.route` is the reference statement of where a flit goes next.
`chi_noc_pkg::chi_xp_route` is the other one. They were written from the
specification rather than from each other, and //hardware/ip/chi_noc/test walks
every input through both and requires them to agree.

Getting the model to the testbench is what this file is for. The alternative --
reimplementing XY routing in C++ inside the test -- would produce a *third*
statement, and a test that reimplements what it is checking passes whenever the
author makes the same mistake twice.

The table is exhaustive over (my_x, my_y, tgt_id), which for the reference
layout is 16 x 16 x 2048 entries and half a megabyte. It is a build output, so
its size costs nothing and nobody reviews a diff of it.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

from nocgen.config import NodeIdLayout
from nocgen.routing import Target, route_mask


def build(layout: NodeIdLayout) -> bytes:
    """One byte per (my_x, my_y, tgt_id): the one-hot port a flit leaves by.

    Indexed `((my_x << y_width) | my_y) << nodeid_width | tgt_id`, which is the
    order the loops below write and the test reads. Six ports fit in a byte, so
    there is no packing to get wrong.

    `route_mask` rather than `route`, because the sweep is over every NodeID the
    layout can express and some of them name a device port no crosspoint has.
    Those are zero here and zero in the RTL, and that agreement is worth checking
    -- it is the case a testbench driving only sensible targets would miss.
    """
    table = bytearray()
    for my_x in range(1 << layout.x_width):
        for my_y in range(1 << layout.y_width):
            for node_id in range(1 << layout.width):
                target = Target.decode(node_id, layout)
                table.append(route_mask(my_x, my_y, target))
    return bytes(table)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="route_table", description=__doc__)
    parser.add_argument("--x-width", type=int, default=4)
    parser.add_argument("--y-width", type=int, default=4)
    parser.add_argument("--port-width", type=int, default=3)
    parser.add_argument("--out", required=True, type=Path)
    args = parser.parse_args(argv)

    layout = NodeIdLayout(x_width=args.x_width, y_width=args.y_width, port_width=args.port_width)
    args.out.write_bytes(build(layout))
    return 0


if __name__ == "__main__":
    sys.exit(main())
