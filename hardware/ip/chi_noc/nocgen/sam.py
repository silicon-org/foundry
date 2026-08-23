"""The System Address Map: which home node owns a line.

A request node cannot send a REQ without a TgtID, and the TgtID of a coherent
request is the HN-F that owns the address. Something has to make that decision
before the flit is injected, and it has to make the same decision at every
request node in the machine -- two RN-Fs disagreeing about who owns a line is a
coherence failure that no amount of fabric correctness recovers from.

So the table is generated once, here, and emitted into the package every request
node includes. There is no second copy to drift.
"""

from __future__ import annotations

import dataclasses

from .config import Topology


@dataclasses.dataclass(frozen=True, slots=True)
class Region:
    """One decoded range, with its home nodes already resolved to NodeIDs."""

    name: str
    base: int
    size: int
    #: HN-F NodeIDs, in interleave order. Consecutive lines go to consecutive
    #: entries.
    targets: tuple[int, ...]

    @property
    def limit(self) -> int:
        return self.base + self.size

    def contains(self, address: int) -> bool:
        return self.base <= address < self.limit


@dataclasses.dataclass(frozen=True, slots=True)
class AddressMap:
    regions: tuple[Region, ...]
    line_bytes: int

    def target(self, address: int) -> int | None:
        """The HN-F NodeID owning `address`, or None if nothing claims it.

        Interleaving is the line index modulo the number of home nodes. Plain
        modulo rather than a hash: with a power-of-two count it is a bit slice
        in RTL, and where the count is not a power of two the generator says so
        rather than the hardware paying for a divider.
        """
        for region in self.regions:
            if region.contains(address):
                line = (address - region.base) // self.line_bytes
                return region.targets[line % len(region.targets)]
        return None

    def coverage(self) -> int:
        return sum(region.size for region in self.regions)


def build(topology: Topology) -> AddressMap:
    """Resolve the config's ranges into NodeIDs.

    Overlap and unknown home nodes are already rejected by `Topology`; what is
    checked here is the thing only the resolved form can see -- that an
    interleave count which is not a power of two would cost a divider.
    """
    layout = topology.node_id
    regions: list[Region] = []
    for entry in sorted(topology.address_map, key=lambda e: e.base):
        targets = []
        for name in entry.interleave:
            device = topology.device(name)
            targets.append(layout.encode(device.x, device.y, device.port))

        count = len(targets)
        if count & (count - 1):
            raise ValueError(
                f"range {entry.name!r} interleaves over {count} home nodes. "
                f"A power of two makes the select a bit slice; {count} makes it "
                f"a modulo, which is a divider in RTL."
            )
        regions.append(
            Region(
                name=entry.name,
                base=entry.base,
                size=entry.size,
                targets=tuple(targets),
            )
        )
    return AddressMap(regions=tuple(regions), line_bytes=topology.line_bytes)
