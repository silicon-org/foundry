"""Rendering a network as the three things that consume it.

SystemVerilog for the build, a package for the RTL that talks to it, and JSON
for the testbench. All three from one `Network`, which is the point: a
scoreboard that reads the JSON and RTL that reads the package are describing the
same object, and there is no third place where they could drift apart.
"""

from __future__ import annotations

import dataclasses
import json
from pathlib import Path

import jinja2

from .network import Crosspoint, Network
from .routing import Direction, arrival_direction, path

_TEMPLATES = Path(__file__).parent / "templates"

#: SystemVerilog names for the directions, matching chi_noc_pkg.
_DIR_NAME = {
    Direction.EAST: "CHI_XP_EAST",
    Direction.WEST: "CHI_XP_WEST",
    Direction.NORTH: "CHI_XP_NORTH",
    Direction.SOUTH: "CHI_XP_SOUTH",
    Direction.P0: "CHI_XP_P0",
    Direction.P1: "CHI_XP_P1",
}


def _environment() -> jinja2.Environment:
    return jinja2.Environment(
        loader=jinja2.FileSystemLoader(_TEMPLATES),
        # Whitespace control is on so the templates can be indented for reading
        # without that indentation reaching the generated file.
        trim_blocks=True,
        lstrip_blocks=True,
        keep_trailing_newline=True,
        undefined=jinja2.StrictUndefined,
    )


def _sv_literal(width: int, value: int) -> str:
    """A sized SystemVerilog hex literal, with the digits it needs and no more."""
    digits = (width + 3) // 4
    return f"{width}'h{value:0{digits}x}"


def _addr_width(network: Network) -> int:
    """Enough bits for every address the map mentions, rounded to CHI's 48.

    Fixed at chi_pkg's reference width rather than computed, because the SAM
    compares against an address that arrives on a REQ flit and that flit's field
    is 48 bits whatever this map happens to use.
    """
    del network
    return 48


def render_package(network: Network, source: str) -> str:
    env = _environment()
    width = network.config.node_id.width
    addr_width = _addr_width(network)
    max_interleave = max((len(r.targets) for r in network.address_map.regions), default=1)

    # Literals are formatted here rather than in the template. Jinja can call a
    # function but its `map` filter takes the *name* of a filter, so formatting a
    # list in the template means registering filters for what is really just
    # string building -- and the template is easier to read without it.
    regions = [
        {
            "name": region.name,
            "base": _sv_literal(addr_width, region.base),
            "limit": _sv_literal(addr_width, region.limit),
            "ways": len(region.targets),
            # Padded out to MaxInterleave, because the array is rectangular and a
            # region with fewer home nodes still occupies a full row of it.
            "targets": ", ".join(
                _sv_literal(width, target)
                for target in region.targets + (0,) * (max_interleave - len(region.targets))
            ),
        }
        for region in network.address_map.regions
    ]

    # Latency is `per_hop * hops + overhead`, so the two coefficients travel
    # rather than a single number for one hop count -- a testbench can then check
    # every pair rather than the average.
    at_zero = network.zero_load_latency(0)
    at_one = network.zero_load_latency(1)

    return env.get_template("noc_pkg.sv.jinja").render(
        network=network,
        cfg=network.config,
        source=source,
        regions=regions,
        max_interleave=max_interleave,
        addr_width=addr_width,
        nid=lambda value: _sv_literal(width, value),
        latency_per_hop=at_one - at_zero,
        latency_overhead=at_zero,
        saturation_per_mille=round(network.saturation_bound * 1000),
        mean_hops_per_mille=round(network.mean_hops * 1000),
    )


def render_netlist(network: Network, source: str) -> str:
    env = _environment()
    width = network.config.node_id.width

    def links(xp: Crosspoint) -> list[tuple[str, str, int, int]]:
        return [
            (_DIR_NAME[direction], _DIR_NAME[arrival_direction(direction)], nx, ny)
            for direction, (nx, ny) in sorted(xp.neighbours.items())
        ]

    def dangling(xp: Crosspoint) -> list[str]:
        """Compass and device ports this crosspoint has nothing on."""
        out = []
        for direction in Direction:
            if direction in xp.neighbours:
                continue
            if direction.is_device and (direction - Direction.P0) in xp.devices:
                continue
            if direction.is_device and (direction - Direction.P0) >= network.config.device_ports:
                continue
            out.append(_DIR_NAME[direction])
        return out

    order = {port.device.name: index for index, port in enumerate(network.ports)}

    def device_index(port) -> int:
        return order[port.device.name]

    def enable_bits(xp: Crosspoint) -> str:
        """Port-enable parameter, MSB first, so the literal reads P1 down to East."""
        bits = xp.port_enable(network.config.device_ports)
        return "".join("1" if bit else "0" for bit in reversed(bits))

    return env.get_template("noc.sv.jinja").render(
        network=network,
        cfg=network.config,
        source=source,
        n_dir=len(Direction),
        nid=lambda value: _sv_literal(width, value),
        links=links,
        dangling=dangling,
        enable_bits=enable_bits,
        device_index=device_index,
        dir_name=lambda index: _DIR_NAME[Direction(Direction.P0 + index)],
    )


def render_json(network: Network, source: str) -> str:
    """Every fact the RTL was generated from, for whatever drives it.

    Including the expected route for every ordered device pair. That is the
    scoreboard's oracle and M2's reference for the route function, and having it
    here means a testbench never recomputes routing -- a check that recomputes
    what it is checking proves nothing.
    """
    cfg = network.config
    devices = [
        {
            "name": port.device.name,
            "kind": str(port.device.kind),
            "x": port.device.x,
            "y": port.device.y,
            "port": port.device.port,
            "node_id": port.node_id,
        }
        for port in network.ports
    ]

    routes = []
    for src in network.ports:
        for dst in network.ports:
            steps = path(network.target(src.device.name), network.target(dst.device.name))
            routes.append(
                {
                    "src": src.device.name,
                    "dst": dst.device.name,
                    "hops": len(steps) - 1,
                    "latency": network.zero_load_latency(len(steps) - 1),
                    "path": [{"x": step.x, "y": step.y, "out": int(step.out)} for step in steps],
                }
            )

    document = {
        "name": network.name,
        "source": source,
        "description": cfg.description,
        "mesh": {
            "size_x": cfg.size_x,
            "size_y": cfg.size_y,
            "device_ports": cfg.device_ports,
            "line_bytes": cfg.line_bytes,
        },
        "node_id": {
            "x_width": cfg.node_id.x_width,
            "y_width": cfg.node_id.y_width,
            "port_width": cfg.node_id.port_width,
            "width": cfg.node_id.width,
        },
        "directions": {d.name: int(d) for d in Direction},
        "devices": devices,
        "address_map": [
            {
                "name": region.name,
                "base": region.base,
                "size": region.size,
                "targets": list(region.targets),
            }
            for region in network.address_map.regions
        ],
        # What M3's throughput test asserts against, computed from this topology
        # rather than quoted from a textbook that assumed a different one.
        "analysis": {
            "mean_hops": network.mean_hops,
            "saturation_bound": network.saturation_bound,
            "zero_load_latency_mean": network.zero_load_latency(round(network.mean_hops)),
        },
        "routes": routes,
    }
    return json.dumps(document, indent=2, sort_keys=False) + "\n"


@dataclasses.dataclass(frozen=True, slots=True)
class Artefacts:
    netlist: str
    package: str
    manifest: str

    def write(self, directory: Path, name: str) -> list[Path]:
        directory.mkdir(parents=True, exist_ok=True)
        written = []
        for suffix, text in (
            ("_noc.sv", self.netlist),
            ("_noc_pkg.sv", self.package),
            ("_noc.json", self.manifest),
        ):
            target = directory / f"{name}{suffix}"
            target.write_text(text)
            written.append(target)
        return written


def render(network: Network, source: str) -> Artefacts:
    return Artefacts(
        netlist=render_netlist(network, source),
        package=render_package(network, source),
        manifest=render_json(network, source),
    )
