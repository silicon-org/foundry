"""The routing model, which is what the RTL is later checked against.

If these pass and `chi_xp_channel` agrees with `route` for every input, the
fabric's routing is correct -- so these tests carry the weight for a property
that no amount of simulation would establish by sampling.
"""

from __future__ import annotations

import itertools

import pytest

from nocgen.config import NodeIdLayout
from nocgen.routing import (
    FORBIDDEN_TURNS,
    Direction,
    Target,
    arrival_direction,
    device_port,
    hops,
    path,
    route,
)

SIZE = 4
PORTS = 2

SITES = list(itertools.product(range(SIZE), range(SIZE)))
TARGETS = [Target(x=x, y=y, port=p) for x, y in SITES for p in range(PORTS)]


def test_nodeid_round_trips_over_the_whole_space():
    """Encode and decode are inverses for every NodeID the layout can express.

    Exhaustive rather than sampled: 2^11 is nothing, and this is the function
    every other fact about a device's identity rests on.
    """
    layout = NodeIdLayout()
    assert layout.width == 11
    for node_id in range(1 << layout.width):
        assert Target.decode(node_id, layout).encode(layout) == node_id


def test_nodeid_matches_the_documented_reference():
    """The table in //hardware/ip/chi_noc/README.md, in code.

    The document states these and M0's gate was passing them; if the layout ever
    changes, this fails before the document quietly becomes wrong.
    """
    layout = NodeIdLayout()
    assert layout.encode(0, 0, 0) == 0x000
    assert layout.encode(3, 0, 0) == 0x180
    assert layout.encode(0, 1, 0) == 0x008
    assert layout.encode(2, 2, 0) == 0x110
    assert layout.encode(3, 3, 0) == 0x198
    assert layout.encode(0, 0, 1) == 0x001


@pytest.mark.parametrize("site", SITES)
def test_route_is_total(site):
    """Every position and target yields a direction.

    A crosspoint cannot refuse a flit, so a route function with a gap in it
    would drop one -- silently, in the one place a network must never be silent.
    """
    x, y = site
    for target in TARGETS:
        assert isinstance(route(x, y, target), Direction)


def test_route_delivers_locally_only_at_the_destination():
    for x, y in SITES:
        for target in TARGETS:
            direction = route(x, y, target)
            arrived = (x, y) == (target.x, target.y)
            assert direction.is_device == arrived
            if arrived:
                assert direction == device_port(target.port)


@pytest.mark.parametrize("src", TARGETS)
def test_paths_are_minimal_and_dimension_ordered(src):
    for dst in TARGETS:
        steps = path(src, dst)

        # Terminates where it was addressed.
        assert steps[-1].out == device_port(dst.port)
        assert (steps[-1].x, steps[-1].y) == (dst.x, dst.y)

        # Minimal: one crosspoint per hop, plus the one it started on.
        assert len(steps) == hops(src, dst) + 1

        # Dimension-ordered: every X move precedes every Y move. This is the
        # property the deadlock argument rests on, so it is checked directly
        # rather than inferred from the absence of a deadlock in simulation.
        moves = [step.out for step in steps[:-1]]
        verticals = [i for i, d in enumerate(moves) if d.is_vertical]
        horizontals = [i for i, d in enumerate(moves) if d.is_horizontal]
        assert len(verticals) + len(horizontals) == len(moves)
        if verticals and horizontals:
            assert max(horizontals) < min(verticals)


def test_no_path_ever_takes_a_forbidden_turn():
    """The two turns that do not exist, over every pair in the mesh.

    `chi_xp_channel` asserts on these and M5 requires their coverage bins to
    stay empty. This is the same claim, made where it is cheap to make it
    exhaustively.
    """
    for src in TARGETS:
        for dst in TARGETS:
            steps = path(src, dst)
            for previous, current in zip(steps, steps[1:], strict=False):
                arrival = arrival_direction(previous.out)
                assert (arrival, current.out) not in FORBIDDEN_TURNS


def test_forbidden_turns_are_the_four_we_think_they_are():
    assert FORBIDDEN_TURNS == {
        (Direction.NORTH, Direction.EAST),
        (Direction.NORTH, Direction.WEST),
        (Direction.SOUTH, Direction.EAST),
        (Direction.SOUTH, Direction.WEST),
    }


def test_arrival_is_the_opposite_of_departure():
    for direction in (Direction.EAST, Direction.WEST, Direction.NORTH, Direction.SOUTH):
        assert arrival_direction(arrival_direction(direction)) == direction


def test_direction_encoding_matches_the_rtl_order():
    """East, West, North, South, P0, P1 -- OpenNoC's order, and chi_noc_pkg's.

    The generated netlist indexes ports by these numbers, so a reordering here
    silently rewires every mesh. Pinned.
    """
    assert [int(d) for d in Direction] == [0, 1, 2, 3, 4, 5]
    assert int(Direction.EAST) == 0
    assert int(Direction.P0) == 4
