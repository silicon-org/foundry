"""The address map.

Two request nodes disagreeing about which home node owns a line is a coherence
failure the fabric cannot detect and no protocol check would survive. The map is
generated once for exactly that reason, so what is checked here is that the one
answer it gives is total, disjoint and evenly spread.
"""

from __future__ import annotations

import pytest

from nocgen import sam
from nocgen.config import Topology

FOUR_HOMES = Topology.parse(
    {
        "name": "t",
        "size_x": 2,
        "size_y": 2,
        "line_bytes": 64,
        "devices": [
            {"name": "hnf0", "kind": "HN-F", "x": 0, "y": 0},
            {"name": "hnf1", "kind": "HN-F", "x": 1, "y": 0},
            {"name": "hnf2", "kind": "HN-F", "x": 0, "y": 1},
            {"name": "hnf3", "kind": "HN-F", "x": 1, "y": 1},
        ],
        "address_map": [
            {
                "name": "dram",
                "base": 0x8000_0000,
                "size": 0x1_0000,
                "interleave": ["hnf0", "hnf1", "hnf2", "hnf3"],
            }
        ],
    }
)


def test_every_address_in_a_region_resolves_to_one_of_its_home_nodes():
    mapping = sam.build(FOUR_HOMES)
    region = mapping.regions[0]
    for offset in range(0, region.size, 64):
        assert mapping.target(region.base + offset) in region.targets


def test_addresses_outside_every_region_resolve_to_nothing():
    """A hole answers None rather than guessing.

    Guessing would send a request to a home node that does not own the line,
    which is worse than the bus error the caller gets for asking.
    """
    mapping = sam.build(FOUR_HOMES)
    assert mapping.target(0) is None
    assert mapping.target(0x8000_0000 - 1) is None
    assert mapping.target(0x8001_0000) is None


def test_consecutive_lines_go_to_consecutive_home_nodes():
    """The whole point of interleaving: a linear sweep uses the whole fabric."""
    mapping = sam.build(FOUR_HOMES)
    region = mapping.regions[0]
    seen = [mapping.target(region.base + line * 64) for line in range(8)]
    assert seen == list(region.targets) * 2


def test_interleaving_is_even_over_a_region():
    mapping = sam.build(FOUR_HOMES)
    region = mapping.regions[0]
    counts = dict.fromkeys(region.targets, 0)
    for offset in range(0, region.size, 64):
        counts[mapping.target(region.base + offset)] += 1
    assert len(set(counts.values())) == 1


def test_every_byte_of_a_line_resolves_the_same_way():
    """Interleaving is per line, not per byte; a line must not be split."""
    mapping = sam.build(FOUR_HOMES)
    base = mapping.regions[0].base
    assert len({mapping.target(base + byte) for byte in range(64)}) == 1
    assert mapping.target(base + 64) != mapping.target(base)


def test_a_non_power_of_two_interleave_is_refused():
    """It would be a divider in RTL, and nobody meant to ask for one."""
    topology = Topology.parse(
        {
            "name": "t",
            "size_x": 2,
            "size_y": 2,
            "devices": [
                {"name": "hnf0", "kind": "HN-F", "x": 0, "y": 0},
                {"name": "hnf1", "kind": "HN-F", "x": 1, "y": 0},
                {"name": "hnf2", "kind": "HN-F", "x": 0, "y": 1},
            ],
            "address_map": [
                {
                    "name": "dram",
                    "base": 0,
                    "size": 0x1000,
                    "interleave": ["hnf0", "hnf1", "hnf2"],
                }
            ],
        }
    )
    with pytest.raises(ValueError, match="interleaves over 3 home nodes"):
        sam.build(topology)


def test_coverage_is_the_sum_of_the_regions():
    assert sam.build(FOUR_HOMES).coverage() == 0x1_0000
