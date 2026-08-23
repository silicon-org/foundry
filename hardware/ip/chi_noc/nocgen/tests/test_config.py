"""What a bad topology does.

Every one of these is a mistake somebody will make, and each must fail here --
with the field named -- rather than as a wrong NodeID in generated RTL that
elaborates fine and misroutes at run time.
"""

from __future__ import annotations

import pytest

from nocgen.config import NodeIdLayout, Topology

BASE = {
    "name": "t",
    "size_x": 2,
    "size_y": 2,
    "devices": [
        {"name": "rnf0", "kind": "RN-F", "x": 0, "y": 0},
        {"name": "hnf0", "kind": "HN-F", "x": 1, "y": 1},
    ],
}


def make(**overrides):
    return Topology.parse(BASE | overrides)


def test_the_base_topology_is_valid():
    assert make().size_x == 2


def test_nodeid_must_fit_a_chi_nodeid():
    with pytest.raises(ValueError, match="CHI permits 7 to 16"):
        NodeIdLayout(x_width=1, y_width=1, port_width=1)
    with pytest.raises(ValueError, match="CHI permits 7 to 16"):
        NodeIdLayout(x_width=8, y_width=8, port_width=4)


def test_device_off_the_mesh_is_rejected():
    with pytest.raises(ValueError, match="off a 2x2 mesh"):
        make(devices=[{"name": "rnf0", "kind": "RN-F", "x": 5, "y": 0}])


def test_two_devices_on_one_port_are_rejected():
    with pytest.raises(ValueError, match="both on P0"):
        make(
            devices=[
                {"name": "rnf0", "kind": "RN-F", "x": 0, "y": 0},
                {"name": "rnf1", "kind": "RN-F", "x": 0, "y": 0},
            ]
        )


def test_duplicate_names_are_rejected():
    with pytest.raises(ValueError, match="two devices are called"):
        make(
            devices=[
                {"name": "rnf0", "kind": "RN-F", "x": 0, "y": 0},
                {"name": "rnf0", "kind": "RN-F", "x": 1, "y": 0},
            ]
        )


def test_a_port_beyond_the_crosspoints_ports_is_rejected():
    with pytest.raises(ValueError, match="is on port P3"):
        make(devices=[{"name": "rnf0", "kind": "RN-F", "x": 0, "y": 0, "port": 3}])


def test_a_mesh_wider_than_nodeid_allows_is_rejected():
    with pytest.raises(ValueError, match="columns need more than"):
        make(size_x=64, node_id={"x_width": 2, "y_width": 4, "port_width": 3})


def test_overlapping_ranges_are_rejected():
    with pytest.raises(ValueError, match="overlap"):
        make(
            address_map=[
                {"name": "a", "base": 0, "size": 0x2000, "interleave": ["hnf0"]},
                {"name": "b", "base": 0x1000, "size": 0x2000, "interleave": ["hnf0"]},
            ]
        )


def test_abutting_ranges_are_fine():
    """A hole is legal and so is a seam; only an overlap is not."""
    topology = make(
        address_map=[
            {"name": "a", "base": 0, "size": 0x1000, "interleave": ["hnf0"]},
            {"name": "b", "base": 0x1000, "size": 0x1000, "interleave": ["hnf0"]},
        ]
    )
    assert len(topology.address_map) == 2


def test_a_range_must_interleave_over_home_nodes():
    with pytest.raises(ValueError, match="not an HN-F"):
        make(address_map=[{"name": "a", "base": 0, "size": 0x1000, "interleave": ["rnf0"]}])


def test_a_range_must_be_a_whole_number_of_lines():
    with pytest.raises(ValueError, match="not a whole number of 64-byte lines"):
        make(address_map=[{"name": "a", "base": 0, "size": 100, "interleave": ["hnf0"]}])


def test_unknown_keys_are_rejected():
    """extra='forbid' everywhere, so a typo is an error and not a default.

    A misspelled `device_ports` that silently keeps the default is exactly the
    kind of thing that shows up as a mysterious elaboration failure later.
    """
    with pytest.raises(ValueError):
        make(devcie_ports=4)
