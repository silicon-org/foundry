"""The shipped topologies, end to end.

Two jobs. The first is the golden files: generation is deterministic, so a diff
in the output is a change somebody made and should be looking at. The second is
the analysis -- the numbers //hardware/ip/chi_noc/README.md quotes and M3's
throughput test asserts against. A document that drifts from the code is worse
than no document, so the document's numbers are tested.
"""

from __future__ import annotations

import json
import os
from pathlib import Path

import pytest
import yaml

from nocgen.config import Topology
from nocgen.emit import render
from nocgen.network import elaborate
from nocgen.routing import Direction, path

_HERE = Path(__file__).parent
EXAMPLES = _HERE.parent / "examples"
GOLDEN = _HERE / "golden"

NAMES = ["mesh2x2", "mesh4x4", "irregular"]


def load(name: str):
    return elaborate(Topology.parse(yaml.safe_load((EXAMPLES / f"{name}.yml").read_text())))


@pytest.fixture(scope="module")
def mesh4x4():
    return load("mesh4x4")


@pytest.mark.parametrize("name", NAMES)
def test_matches_golden(name):
    """Regenerate with UPDATE_GOLDEN=1 and read the diff before committing it."""
    artefacts = render(load(name), source=f"{name}.yml")
    produced = {
        f"{name}_noc.sv": artefacts.netlist,
        f"{name}_noc_pkg.sv": artefacts.package,
        f"{name}_noc.json": artefacts.manifest,
    }

    if os.environ.get("UPDATE_GOLDEN"):
        GOLDEN.mkdir(parents=True, exist_ok=True)
        for filename, text in produced.items():
            (GOLDEN / filename).write_text(text)
        pytest.skip("golden files rewritten")

    for filename, text in produced.items():
        expected = GOLDEN / filename
        assert expected.exists(), f"{filename} has no golden; run with UPDATE_GOLDEN=1"
        assert text == expected.read_text(), f"{filename} differs from its golden"


@pytest.mark.parametrize("name", NAMES)
def test_generation_is_deterministic(name):
    """Two runs, one output. Otherwise the golden test is a coin toss."""
    network = load(name)
    first = render(network, source=f"{name}.yml")
    second = render(load(name), source=f"{name}.yml")
    assert first == second


@pytest.mark.parametrize("name", NAMES)
def test_every_ordered_pair_is_routable(name):
    """The gate: every device can reach every device, minimally.

    Over the real topologies rather than a synthetic mesh, so an irregular
    placement or a doubly-populated crosspoint is covered by the same check.
    """
    network = load(name)
    targets = {port.device.name: network.target(port.device.name) for port in network.ports}
    for src_name, src in targets.items():
        for dst_name, dst in targets.items():
            steps = path(src, dst)
            assert (steps[-1].x, steps[-1].y) == (dst.x, dst.y), f"{src_name} -> {dst_name}"
            assert steps[-1].out == Direction(Direction.P0 + dst.port)


@pytest.mark.parametrize("name", NAMES)
def test_manifest_routes_agree_with_the_model(name):
    """The JSON a testbench reads is the model, not a paraphrase of it."""
    network = load(name)
    manifest = json.loads(render(network, source="x").manifest)
    by_pair = {(r["src"], r["dst"]): r for r in manifest["routes"]}
    assert len(by_pair) == len(network.ports) ** 2
    for (src_name, dst_name), record in by_pair.items():
        steps = path(network.target(src_name), network.target(dst_name))
        assert record["hops"] == len(steps) - 1
        assert [s["out"] for s in record["path"]] == [int(s.out) for s in steps]


# -- the numbers the README commits to ---------------------------------------


def test_mesh4x4_nodeids_match_the_readme(mesh4x4):
    expected = {
        "rnf0": 0x000,
        "rnf1": 0x080,
        "rnf2": 0x100,
        "rnf3": 0x180,
        "hnf0": 0x008,
        "hnf1": 0x088,
        "hnf2": 0x108,
        "hnf3": 0x188,
        "snf0": 0x010,
        "rni0": 0x090,
        "hni0": 0x110,
        "snf1": 0x190,
        "rnf4": 0x018,
        "rnf5": 0x098,
        "rnf6": 0x118,
        "rnf7": 0x198,
    }
    assert {p.device.name: p.node_id for p in mesh4x4.ports} == expected


def test_mesh4x4_mean_hop_count_is_two_and_a_half(mesh4x4):
    """2(k^2-1)/3k at k = 4, which the README quotes."""
    assert mesh4x4.mean_hops == pytest.approx(2.5)


def test_mesh4x4_zero_load_latency_matches_the_readme(mesh4x4):
    """3H + 4 cycles: the per-stage budget M2 has to hit."""
    assert mesh4x4.zero_load_latency(0) == 4
    assert mesh4x4.zero_load_latency(6) == 22
    assert all(mesh4x4.zero_load_latency(h) == 3 * h + 4 for h in range(7))


def test_mesh4x4_saturates_at_one_flit_per_cycle(mesh4x4):
    """Ejection, bisection and the busiest link all bind at once at this size.

    The README leans on this: the topology offers the microarchitecture no
    excuse, so whatever M3 measures below 1.0 is buffering and arbitration.
    """
    assert mesh4x4.saturation_bound == pytest.approx(1.0)


def test_mesh4x4_link_load_is_the_documented_spread(mesh4x4):
    """48 directed links carrying 12 or 16 of the 256 ordered pairs."""
    from nocgen.routing import link_load

    load = link_load(mesh4x4.config)
    assert len(load) == 48
    assert sorted(set(load.values())) == [12, 16]
    assert sum(1 for v in load.values() if v == 16) == 16
