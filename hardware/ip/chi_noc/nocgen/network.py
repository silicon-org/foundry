"""A topology, elaborated.

`config.Topology` is what someone wrote down. This is what it means: every
crosspoint with its coordinates and enabled ports, every device with its NodeID,
every link with both ends named, and the address map resolved. The templates and
the JSON both render *this*, so the RTL and the testbench are two views of one
object rather than two readings of one YAML file.
"""

from __future__ import annotations

import dataclasses

from . import routing, sam
from .config import Device, Topology
from .routing import Direction


@dataclasses.dataclass(frozen=True, slots=True)
class Port:
    """One device attached to one crosspoint port."""

    device: Device
    node_id: int

    @property
    def direction(self) -> Direction:
        return routing.device_port(self.device.port)


@dataclasses.dataclass(frozen=True, slots=True)
class Crosspoint:
    x: int
    y: int
    #: Compass ports that go somewhere. An edge crosspoint has fewer, and the
    #: disabled ones cost no logic rather than being tied off.
    neighbours: dict[Direction, tuple[int, int]]
    #: Device ports that hold something, by port index.
    devices: dict[int, Port]

    @property
    def instance(self) -> str:
        return f"i_xp_{self.x}_{self.y}"

    def port_enable(self, ports: int) -> list[bool]:
        """One bit per direction, in `Direction` order, for the RTL parameter."""
        enabled = [False] * len(Direction)
        for direction in self.neighbours:
            enabled[direction] = True
        for index in self.devices:
            enabled[routing.device_port(index)] = True
        del ports
        return enabled


@dataclasses.dataclass(frozen=True, slots=True)
class Network:
    config: Topology
    crosspoints: tuple[Crosspoint, ...]
    ports: tuple[Port, ...]
    address_map: sam.AddressMap

    @property
    def name(self) -> str:
        return self.config.name

    def crosspoint(self, x: int, y: int) -> Crosspoint:
        for candidate in self.crosspoints:
            if candidate.x == x and candidate.y == y:
                return candidate
        raise KeyError((x, y))

    def port(self, name: str) -> Port:
        for candidate in self.ports:
            if candidate.device.name == name:
                return candidate
        raise KeyError(name)

    def target(self, name: str) -> routing.Target:
        device = self.port(name).device
        return routing.Target(x=device.x, y=device.y, port=device.port)

    # -- the numbers the README quotes and the throughput test asserts --------

    @property
    def mean_hops(self) -> float:
        return routing.mean_hops(self.config)

    @property
    def saturation_bound(self) -> float:
        return routing.saturation_bound(self.config)

    def zero_load_latency(self, hops: int) -> int:
        """Cycles from injection to ejection over `hops` links.

        Every register on the path costs one cycle and nothing else costs
        anything, because routing, arbitration and the crossbar are all
        combinational. There are exactly two kinds of register: a transmitter's
        flit register, and a receiver's buffer write.

        A path crosses `hops + 1` crosspoints, each contributing one of each, and
        the two device ends contribute one each. So `2 * (hops + 1) + 2`, or
        `2 * hops + 4`.

        Measured, not assumed: //hardware/ip/chi_noc/test drives every ordered
        pair through an otherwise empty mesh and requires this exactly. An
        earlier version of this function charged a crosspoint two cycles on the
        theory that arbitrating took one, and was wrong by a cycle per hop.
        """
        return 2 * (hops + 1) + 2


def elaborate(config: Topology) -> Network:
    """Turn a parsed topology into the network the emitters render."""
    layout = config.node_id

    ports_by_site: dict[tuple[int, int], dict[int, Port]] = {}
    ports: list[Port] = []
    for device in config.devices:
        port = Port(device=device, node_id=layout.encode(device.x, device.y, device.port))
        ports.append(port)
        ports_by_site.setdefault((device.x, device.y), {})[device.port] = port

    crosspoints: list[Crosspoint] = []
    for y in range(config.size_y):
        for x in range(config.size_x):
            neighbours: dict[Direction, tuple[int, int]] = {}
            if x + 1 < config.size_x:
                neighbours[Direction.EAST] = (x + 1, y)
            if x - 1 >= 0:
                neighbours[Direction.WEST] = (x - 1, y)
            if y + 1 < config.size_y:
                neighbours[Direction.NORTH] = (x, y + 1)
            if y - 1 >= 0:
                neighbours[Direction.SOUTH] = (x, y - 1)
            crosspoints.append(
                Crosspoint(
                    x=x,
                    y=y,
                    neighbours=neighbours,
                    devices=ports_by_site.get((x, y), {}),
                )
            )

    return Network(
        config=config,
        crosspoints=tuple(crosspoints),
        ports=tuple(ports),
        address_map=sam.build(config),
    )
