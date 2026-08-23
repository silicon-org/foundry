"""Where a flit goes next.

This is the reference the RTL is checked against. `chi_xp_channel`'s route
computation and `route` below are two statements of one function, and
//hardware/ip/chi_noc/test walks every (position, target) pair through both and
requires them to agree. Keeping the model here rather than in the testbench is
what stops the check becoming a restatement of whatever the RTL happens to do.

Dimension-ordered, X then Y. See the README for why that is deadlock-free and
which two turns therefore do not exist.
"""

from __future__ import annotations

import dataclasses
import enum

from .config import NodeIdLayout, Topology


class Direction(enum.IntEnum):
    """A crosspoint's ports, in the order the RTL indexes them."""

    EAST = 0
    WEST = 1
    NORTH = 2
    SOUTH = 3
    P0 = 4
    P1 = 5

    @property
    def is_device(self) -> bool:
        return self >= Direction.P0

    @property
    def is_vertical(self) -> bool:
        return self in (Direction.NORTH, Direction.SOUTH)

    @property
    def is_horizontal(self) -> bool:
        return self in (Direction.EAST, Direction.WEST)


#: The turns dimension-order routing forbids, and the reason the channel
#: dependency graph is acyclic: X is fully resolved before any Y hop, so nothing
#: ever turns from a vertical link onto a horizontal one. `chi_xp_channel`
#: asserts on these and M5 requires their coverage bins to stay empty.
FORBIDDEN_TURNS: frozenset[tuple[Direction, Direction]] = frozenset(
    (arrival, departure)
    for arrival in (Direction.NORTH, Direction.SOUTH)
    for departure in (Direction.EAST, Direction.WEST)
)


def device_port(index: int) -> Direction:
    return Direction(Direction.P0 + index)


@dataclasses.dataclass(frozen=True, slots=True)
class Target:
    """A NodeID, taken apart."""

    x: int
    y: int
    port: int

    @classmethod
    def decode(cls, node_id: int, layout: NodeIdLayout) -> Target:
        port = node_id & ((1 << layout.port_width) - 1)
        y = (node_id >> layout.port_width) & ((1 << layout.y_width) - 1)
        x = node_id >> (layout.port_width + layout.y_width)
        return cls(x=x & ((1 << layout.x_width) - 1), y=y, port=port)

    def encode(self, layout: NodeIdLayout) -> int:
        return layout.encode(self.x, self.y, self.port)


def route(my_x: int, my_y: int, target: Target) -> Direction:
    """The port a flit at (my_x, my_y) leaves by.

    Deliberately total: every input has an answer, because a crosspoint has no
    way to refuse a flit and dropping one silently is the failure mode this
    whole fabric exists to not have. A target off the mesh still yields a
    direction; that it is off the mesh is the generator's business, checked at
    config time, not something to discover a hop at a time.
    """
    if target.x > my_x:
        return Direction.EAST
    if target.x < my_x:
        return Direction.WEST
    if target.y > my_y:
        return Direction.NORTH
    if target.y < my_y:
        return Direction.SOUTH
    return device_port(target.port)


@dataclasses.dataclass(frozen=True, slots=True)
class Step:
    """One crosspoint on a path, and the port the flit left it by."""

    x: int
    y: int
    out: Direction


def path(src: Target, dst: Target) -> list[Step]:
    """Every hop from the crosspoint holding `src` to the port holding `dst`.

    Walks `route` rather than deriving the answer independently, because the
    point is to check `route`; a second closed form here would only prove that
    two pieces of Python agree. What makes the walk a real check is that it
    terminates, is minimal, and is dimension-ordered -- all three asserted by
    the tests, and none of them true by construction.
    """
    steps: list[Step] = []
    x, y = src.x, src.y
    # A mesh is finite, so a route function that does not loop must arrive. The
    # bound turns a routing bug into a failed assertion instead of a hung test.
    for _ in range((abs(dst.x - x) + abs(dst.y - y)) + 1):
        out = route(x, y, dst)
        steps.append(Step(x=x, y=y, out=out))
        if out.is_device:
            return steps
        if out is Direction.EAST:
            x += 1
        elif out is Direction.WEST:
            x -= 1
        elif out is Direction.NORTH:
            y += 1
        else:
            y -= 1
    raise AssertionError(f"route from {src} to {dst} did not arrive")


def hops(src: Target, dst: Target) -> int:
    """Manhattan distance: the number of links a minimal path uses."""
    return abs(dst.x - src.x) + abs(dst.y - src.y)


def arrival_direction(step_out: Direction) -> Direction:
    """The port a flit enters the next crosspoint by, having left through `step_out`."""
    return {
        Direction.EAST: Direction.WEST,
        Direction.WEST: Direction.EAST,
        Direction.NORTH: Direction.SOUTH,
        Direction.SOUTH: Direction.NORTH,
    }[step_out]


def link_load(topology: Topology) -> dict[tuple[int, int, Direction], int]:
    """How many ordered device pairs use each directed inter-crosspoint link.

    The saturation bound in the README comes from the maximum of this: a link
    carrying a fraction f of all traffic saturates when the per-device injection
    rate reaches (number of devices * f) flits per cycle. Computing it here
    rather than quoting a textbook means the bound tracks the topology, and the
    throughput test can assert against the network it is actually driving.
    """
    targets = [Target(x=d.x, y=d.y, port=d.port) for d in topology.devices]
    load: dict[tuple[int, int, Direction], int] = {}
    for src in targets:
        for dst in targets:
            for step in path(src, dst):
                if step.out.is_device:
                    continue
                key = (step.x, step.y, step.out)
                load[key] = load.get(key, 0) + 1
    return load


def saturation_bound(topology: Topology) -> float:
    """Flits per cycle per device, per channel class, that this topology allows.

    The smallest of three: ejection (one flit per device port per cycle), and
    the busiest directed link. Both are computed, not assumed -- an irregular
    topology has no textbook to quote.
    """
    devices = len(topology.devices)
    if devices == 0:
        return 0.0

    # Ejection: every device receives an equal share of what everyone injects.
    bound = 1.0

    load = link_load(topology)
    if load:
        pairs = devices * devices
        busiest = max(load.values())
        # A link carries (devices * lam * busiest / pairs) flits per cycle.
        bound = min(bound, pairs / (devices * busiest))
    return bound


def mean_hops(topology: Topology) -> float:
    """Mean hop count over ordered device pairs, counting src == dst as zero."""
    targets = [Target(x=d.x, y=d.y, port=d.port) for d in topology.devices]
    if not targets:
        return 0.0
    total = sum(hops(a, b) for a in targets for b in targets)
    return total / (len(targets) ** 2)
