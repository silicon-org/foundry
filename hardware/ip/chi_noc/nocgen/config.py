"""What a topology description is allowed to say.

The YAML a user writes is not the model the rest of nocgen works on. This module
is the boundary: it parses, rejects, and hands on something the other modules may
assume is sane -- coordinates on the mesh, names unique, no address claimed
twice. A malformed topology fails here, naming the field, rather than three
modules later as a wrong NodeID in generated RTL that elaborates cleanly and
misroutes at run time.

Plain dataclasses and explicit checks rather than a validation library. What one
would buy is coercion and unknown-key rejection, which is the fifty lines at the
top of this file; what it costs -- for pydantic, the only real candidate -- is a
Rust toolchain in the dependency graph, because rules_py builds pydantic-core
from its sdist. Not a trade worth making to read a YAML file.
"""

from __future__ import annotations

import dataclasses
import enum
import types
import typing


class ConfigError(ValueError):
    """A topology description that cannot be built.

    Its own type so that a caller can tell a bad description from a bug in the
    generator, which is the difference between fixing your YAML and filing a
    report.
    """


class DeviceKind(enum.StrEnum):
    """The CHI node types a port may hold.

    The fabric does not care -- it routes flits and never decodes an opcode --
    but the address map does, since only an HN-F may own a range, and so does
    anyone reading the generated RTL.
    """

    RN_F = "RN-F"
    RN_I = "RN-I"
    HN_F = "HN-F"
    HN_I = "HN-I"
    SN_F = "SN-F"


def _unwrap_optional(annotation: typing.Any) -> typing.Any:
    """`T | None` -> `T`, leaving anything else alone."""
    if typing.get_origin(annotation) in (typing.Union, types.UnionType):
        args = [a for a in typing.get_args(annotation) if a is not type(None)]
        if len(args) == 1:
            return args[0]
    return annotation


def _coerce(value: typing.Any, annotation: typing.Any, where: str) -> typing.Any:
    """YAML's types into the field's, refusing anything lossy.

    `bool` is checked before `int` on purpose: in Python `True` is an `int`, and
    silently accepting `x: true` as a coordinate is exactly the class of mistake
    this file exists to catch.
    """
    annotation = _unwrap_optional(annotation)
    origin = typing.get_origin(annotation)

    if origin is list:
        if not isinstance(value, list):
            raise ConfigError(f"{where}: expected a list, got {type(value).__name__}")
        (item,) = typing.get_args(annotation)
        return [_coerce(v, item, f"{where}[{i}]") for i, v in enumerate(value)]

    if isinstance(annotation, type) and issubclass(annotation, enum.Enum):
        try:
            return annotation(value)
        except ValueError:
            allowed = ", ".join(str(m.value) for m in annotation)
            raise ConfigError(f"{where}: {value!r} is not one of {allowed}") from None

    if dataclasses.is_dataclass(annotation):
        return _build(annotation, value, where)

    if annotation is int:
        if isinstance(value, bool) or not isinstance(value, int):
            raise ConfigError(f"{where}: expected an integer, got {value!r}")
        return value

    if annotation is str:
        if not isinstance(value, str):
            raise ConfigError(f"{where}: expected a string, got {value!r}")
        return value

    return value


def _build(cls: type, raw: typing.Any, where: str) -> typing.Any:
    """A dataclass from a mapping, with unknown keys refused.

    Refused rather than ignored: a misspelled `device_ports` that quietly keeps
    the default is a topology nobody asked for, generated without complaint.
    """
    if not isinstance(raw, dict):
        raise ConfigError(f"{where}: expected a mapping, got {type(raw).__name__}")

    fields = {f.name: f for f in dataclasses.fields(cls)}
    unknown = set(raw) - set(fields)
    if unknown:
        known = ", ".join(sorted(fields))
        raise ConfigError(
            f"{where}: unknown {'keys' if len(unknown) > 1 else 'key'} "
            f"{', '.join(sorted(unknown))}. Known: {known}"
        )

    hints = typing.get_type_hints(cls)
    kwargs = {}
    for name, field in fields.items():
        prefix = f"{where}.{name}" if where else name
        if name in raw:
            kwargs[name] = _coerce(raw[name], hints[name], prefix)
        elif field.default is not dataclasses.MISSING:
            kwargs[name] = field.default
        elif field.default_factory is not dataclasses.MISSING:  # type: ignore[misc]
            kwargs[name] = field.default_factory()  # type: ignore[misc]
        else:
            raise ConfigError(f"{prefix}: required")
    return cls(**kwargs)


@dataclasses.dataclass(frozen=True, slots=True)
class NodeIdLayout:
    """How X, Y and the port index are packed into a NodeID.

    X above Y above the port index, which is CMN's convention. The default sums
    to the 11 bits `chi_pkg::CHI_NODEID_WIDTH` declares, with nothing wasted.
    """

    x_width: int = 4
    y_width: int = 4
    port_width: int = 3

    def __post_init__(self) -> None:
        for name in ("x_width", "y_width", "port_width"):
            if getattr(self, name) < 1:
                raise ConfigError(f"node_id.{name}: must be at least 1")
        # The specification permits 7 to 16; chi_pkg's reference link uses 11.
        if not 7 <= self.width <= 16:
            raise ConfigError(
                f"node_id: {self.width} bits; CHI permits 7 to 16. Got "
                f"x={self.x_width} + y={self.y_width} + port={self.port_width}."
            )

    @property
    def width(self) -> int:
        return self.x_width + self.y_width + self.port_width

    def encode(self, x: int, y: int, port: int) -> int:
        """The NodeID of a device port. The inverse of what the RTL slices out."""
        return (x << (self.y_width + self.port_width)) | (y << self.port_width) | port


@dataclasses.dataclass(frozen=True, slots=True)
class Device:
    """One CHI node, on one port of one crosspoint."""

    name: str
    kind: DeviceKind
    x: int
    y: int
    port: int = 0

    def __post_init__(self) -> None:
        _check_identifier(self.name, "device name")
        for name in ("x", "y", "port"):
            if getattr(self, name) < 0:
                raise ConfigError(f"{self.name}.{name}: must not be negative")


@dataclasses.dataclass(frozen=True, slots=True)
class AddressRange:
    """A span of the address space, and the home nodes that interleave it.

    `interleave` names HN-Fs by device name. Consecutive cache lines go to
    consecutive entries, so a linear sweep spreads over all of them instead of
    hammering one -- which is the only reason a range names more than one.
    """

    name: str
    base: int
    size: int
    interleave: list[str]

    def __post_init__(self) -> None:
        _check_identifier(self.name, "range name")
        if self.base < 0:
            raise ConfigError(f"range {self.name!r}: base must not be negative")
        if self.size <= 0:
            raise ConfigError(f"range {self.name!r}: size must be positive")
        if not self.interleave:
            raise ConfigError(f"range {self.name!r}: interleave names no home node")

    @property
    def limit(self) -> int:
        """One past the last byte."""
        return self.base + self.size


@dataclasses.dataclass(frozen=True, slots=True)
class Topology:
    """A whole network: a mesh of crosspoints, the devices on them, and the map."""

    name: str
    size_x: int
    size_y: int
    devices: list[Device]
    description: str = ""
    # Device ports per crosspoint. Two is what a CMN crosspoint has and what
    # chi_xp implements; the mesh works with one.
    device_ports: int = 2
    # Bytes per cache line, which sets what the address map interleaves on.
    line_bytes: int = 64
    node_id: NodeIdLayout = dataclasses.field(default_factory=NodeIdLayout)
    address_map: list[AddressRange] = dataclasses.field(default_factory=list)

    def __post_init__(self) -> None:
        _check_identifier(self.name, "topology name")
        if self.size_x < 1 or self.size_y < 1:
            raise ConfigError("a mesh needs at least one crosspoint in each dimension")
        if self.device_ports < 1:
            raise ConfigError("a crosspoint needs at least one device port")
        if self.line_bytes <= 0:
            raise ConfigError("line_bytes must be positive")
        if not self.devices:
            raise ConfigError("a topology with no devices has nothing to connect")
        self._check_mesh_fits_nodeid()
        self._check_devices()
        self._check_address_map()

    @classmethod
    def parse(cls, raw: typing.Any) -> Topology:
        """The entry point. Everything past here may assume the result is sane."""
        return _build(cls, raw, "")

    def _check_mesh_fits_nodeid(self) -> None:
        if self.size_x > 1 << self.node_id.x_width:
            raise ConfigError(
                f"{self.size_x} columns need more than the "
                f"{self.node_id.x_width} bits NodeID gives X"
            )
        if self.size_y > 1 << self.node_id.y_width:
            raise ConfigError(
                f"{self.size_y} rows need more than the "
                f"{self.node_id.y_width} bits NodeID gives Y"
            )
        if self.device_ports > 1 << self.node_id.port_width:
            raise ConfigError(
                f"{self.device_ports} device ports need more than the "
                f"{self.node_id.port_width} bits NodeID gives the port index"
            )

    def _check_devices(self) -> None:
        seen_names: set[str] = set()
        seen_slots: dict[tuple[int, int, int], str] = {}
        for device in self.devices:
            if device.name in seen_names:
                raise ConfigError(f"two devices are called {device.name!r}")
            seen_names.add(device.name)

            if not (0 <= device.x < self.size_x and 0 <= device.y < self.size_y):
                raise ConfigError(
                    f"{device.name} sits at ({device.x}, {device.y}), off a "
                    f"{self.size_x}x{self.size_y} mesh"
                )
            if device.port >= self.device_ports:
                raise ConfigError(
                    f"{device.name} is on port P{device.port}, and a crosspoint "
                    f"here has {self.device_ports}"
                )

            slot = (device.x, device.y, device.port)
            if slot in seen_slots:
                raise ConfigError(
                    f"{device.name} and {seen_slots[slot]} are both on "
                    f"P{device.port} of the crosspoint at ({device.x}, {device.y})"
                )
            seen_slots[slot] = device.name

    def _check_address_map(self) -> None:
        """Ranges must name real HN-Fs and must not overlap.

        Holes are legal -- not every address has to be backed -- but two ranges
        claiming one address is a topology that cannot be built, because the
        System Address Map would have to answer twice.
        """
        home_nodes = {d.name for d in self.devices if d.kind is DeviceKind.HN_F}
        for entry in self.address_map:
            for target in entry.interleave:
                if target not in home_nodes:
                    raise ConfigError(
                        f"range {entry.name!r} interleaves over {target!r}, "
                        f"which is not an HN-F in this topology"
                    )
            if entry.size % self.line_bytes:
                raise ConfigError(
                    f"range {entry.name!r} is {entry.size} bytes, not a whole "
                    f"number of {self.line_bytes}-byte lines"
                )

        ordered = sorted(self.address_map, key=lambda e: e.base)
        for lower, upper in zip(ordered, ordered[1:]):
            if lower.limit > upper.base:
                raise ConfigError(
                    f"ranges {lower.name!r} and {upper.name!r} overlap at "
                    f"0x{upper.base:x}"
                )

    def device(self, name: str) -> Device:
        for candidate in self.devices:
            if candidate.name == name:
                return candidate
        raise KeyError(name)


def _check_identifier(value: str, what: str) -> None:
    """Names become SystemVerilog identifiers, so they have to be able to be one."""
    if not value or not value[0].isalpha() or not value.replace("_", "").isalnum():
        raise ConfigError(
            f"{what} {value!r}: must start with a letter and hold only "
            f"letters, digits and underscores -- it becomes an identifier in "
            f"generated RTL"
        )
    if value != value.lower():
        raise ConfigError(f"{what} {value!r}: must be lower case")
