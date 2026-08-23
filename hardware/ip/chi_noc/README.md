# CHI NoC

A mesh of crosspoints that carries CHI between request, home and slave nodes.

```
src/chi_noc_pkg.sv     NodeID layout, directions, the per-class configuration
src/chi_xp_channel.sv  one channel class through one crosspoint
src/chi_xp.sv          four channel classes = one crosspoint
src/chi_sam.sv         address -> home node
nocgen/                the generator that wires crosspoints into a topology
```

**Transport only.** This fabric moves flits and decides nothing. It has no
directory, no snoop filter and no cache: an HN-F is a device that hangs off a
port, played today by `//hardware/vip/chi`. That boundary is what keeps the
fabric verifiable on its own terms — correctness here means every flit arrives
once, at the right port, in order within its stream, and fast enough.

Issue E.b, because `//hardware/ip/chi` is, and that is what
`//hardware/soc/xs_cluster` speaks. Only one file knows that; see *The seam*.

## Four networks, not one

CHI has four channel classes — REQ, RSP, DAT and SNP — and the protocol makes
progress only if each can move while the others are blocked. A home node holding
a REQ it cannot retire until it has sent a SNP and received a RSP is an ordinary
situation, and it deadlocks the moment those three share a buffer.

So they do not share one. `chi_xp` is **four independent switches** with four
independent credit pools that happen to sit in one module and one floorplan
tile. Nothing in `chi_xp_channel` can see another class, which turns the rule
into a property of the structure rather than something a reviewer has to check.
It also means the four differ in width by a factor of six without any of them
paying for the widest:

| class | flit | why it is that size |
|---|---:|---|
| RSP | 73 | no address, no data |
| SNP | 115 + 11 | a line address and a header; see below |
| REQ | 162 | a 48-bit address |
| DAT | 422 | 256 bits of data, 32 of byte enables, 32 of DataCheck |

Those widths are `$bits` of the reference typedefs in `chi_pkg`, and
`//hardware/vip/chi/chi_flit.h` static-asserts every one of them against CHIron.
They are facts, not estimates.

## A snoop has no TgtID

A CHI snoop is sent *on the link to the node being snooped*, so the SNP flit
never needed a target field and does not have one. Inside a mesh it needs one.

A **fabric flit** is therefore a CHI flit plus a routing header. For REQ, RSP and
DAT the header is the TgtID the flit already carries, at no cost. For SNP it is
eleven real bits appended above the flit, written by the HN-facing ingress and
stripped by the RN-facing egress, so that what arrives at a request node is a
CHI SNP flit and nothing else. An assertion at every RN-facing port says so.

This is what OpenNoC does — its HN-F writes the target RN's NodeID above the top
of the flit and its crosspoint is told where to find it by a per-class offset
parameter. The alternative, overloading a field a snoop already has, costs no
wires and makes the first waveform anyone debugs a puzzle. Eleven bits is
cheaper than that.

## NodeID

`chi_pkg::CHI_NODEID_WIDTH` is 11 — XiangShan's choice within the 7-to-16 the
specification allows. It divides exactly:

```
  NodeID[10:7]  X    4 bits, up to 16 columns
  NodeID[ 6:3]  Y    4 bits, up to 16 rows
  NodeID[ 2:0]  P    3 bits, up to 8 device ports per crosspoint
```

X above Y above the port index is CMN's convention and the one `nocgen` emits.
The widths are parameters (`NodeIdXWidth`, `NodeIdYWidth`, `NodeIdPortWidth`),
not constants, because a link with a wider NodeID is allowed to exist; 4/4/3 is
what fills 11 bits with nothing wasted and no mesh anyone will build excluded.

Routing reads those three slices and nothing else. It never decodes an opcode,
never looks at an address, and cannot tell one channel class from another.

## Routing

Dimension-ordered, X then Y. A flit at `(mx, my)` holding target `(tx, ty, p)`
leaves by

```
  tx > mx  ->  East          tx < mx  ->  West
  tx = mx  and  ty > my  ->  North     ty < my  ->  South
  tx = mx  and  ty = my  ->  device port p
```

which is one comparison per dimension and no table. It is minimal — every flit
takes `|Δx| + |Δy|` hops — and it is deadlock-free, for a reason worth stating
rather than assuming: **X is fully resolved before any Y hop is taken, so no
flit ever turns from a Y link onto an X link.** The channel dependency graph has
no cycle because two of its eight turns do not exist.

Those two turns are the fabric's central invariant, so they are checked twice:
an assertion in `chi_xp_channel` fires if a flit arriving on North or South
requests East or West, and M5 requires the corresponding coverage bins to be
**empty**. A turn that is illegal and never exercised and a turn that is illegal
and quietly taken look identical in a coverage report that only counts what
happened.

Table-driven routing, for topologies that are not meshes, is M6 and changes only
the route function.

## The crosspoint

Six ports — East, West, North, South, P0, P1 — of which the four compass ports
connect to neighbours and the two device ports to whatever the topology hangs
there. An edge crosspoint simply has ports disabled, which removes their logic
rather than tying them off.

Each port is a `chi_link_tx_channel` / `chi_link_rx_channel` pair, taken from
`//hardware/ip/chi`. Those are not new: `//hardware/vip/chi` wrote and tested
them for the cluster testbench, and its README said at the time that they were
"synthesisable in shape, so the same module can front real RTL later." This is
later. Between them sits route computation per input and, per output, an
arbiter over every (input port, buffer entry) pair that wants it.

QoS is four priority classes with round-robin inside each, which is OpenNoC's
scheme and CHI's intent. It can starve a low-priority flit indefinitely under
sustained high-priority load. The specification permits that; a fabric that does
it is still a bug in the machine it ends up in, so `chi_xp_channel` counts how
long the oldest ungranted flit has waited and asserts on a bound. Whether that
becomes age-based promotion is a decision for M3, when the hotspot numbers exist.

## The seam

`chi_xp_channel` knows exactly five numbers about the flits it carries:

```
  FlitWidth  TgtIdOffset  TgtIdWidth  QosOffset  QosWidth
```

It does not include `chi_pkg`, does not name a struct, and does not know which
channel class it is. Everything else it needs — that opcode zero is an L-Credit
return — `chi_pkg::chi_*_is_lcrd_return` already answers on its behalf.

`chi_xp.sv` computes those numbers from the `chi_pkg` typedefs and is the **only
file in the fabric that depends on the CHI issue.** At the reference
configuration they come out as:

| class | FlitWidth | TgtIdOffset | QosOffset |
|---|---:|---:|---:|
| REQ | 162 | 4 | 0 |
| RSP | 73 | 4 | 0 |
| DAT | 422 | 4 | 0 |
| SNP | 115 + 11 | 115 | 0 |

QoS is at bit 0 and TgtID immediately above it on three of the four channels,
because `chi_typedef.svh` declares its structs MSB-first and QoS last — the
field order XSCache packs with. The SNP offset is the flit width itself, which
is where the fabric header begins. OpenNoC's crosspoint defaults its offset
parameter to 4 and takes the SNP one separately, for exactly this reason.

Moving to Issue H is then one file. That is what "structured for H" has to mean
if it is to mean anything at all.

## Credits

CHI's flow control is L-Credits: a transmitter sends only while it holds one,
the receiver grants them by pulsing LCRDV, and there is no ready anywhere. A
channel therefore runs at line rate only if the transmitter holds at least as
many credits as the round trip takes to return one — flit out, into the receiver
buffer, LCRDV back — and at `credits / round-trip` of line rate otherwise.

At the per-stage budget below the round trip is three cycles, so **four credits
per channel per port** sustains a flit every cycle with one to spare. That is
already `chi_link_rn`'s default. The specification caps a receiver at 15
outstanding (`chi_pkg::CHI_MAX_LCREDITS`), and exceeding it means the receiver is
broken rather than generous, which the existing assertion says.

## The address map

An RN sends a REQ to the home node that owns the line, so something must turn an
address into a NodeID before the flit is injected. `chi_sam.sv` is that: a small
table of ranges, plus hash interleaving across the HN-Fs within a range, so that
consecutive lines land on different home nodes and a linear sweep spreads over
all of them instead of hammering one.

`nocgen` builds the table and emits it into `<name>_noc_pkg.sv`, and the same
facts go into `<name>_noc.json` for the testbench to read. The generator checks
that the ranges cover the space with no hole and no overlap, in Python, before
any RTL exists.

## The reference topology

`mesh4x4`: sixteen crosspoints, one device on P0 of each, P1 unused.

```
  y=3   RN-F4   RN-F5   RN-F6   RN-F7
  y=2   SN-F0   RN-I    HN-I    SN-F1
  y=1   HN-F0   HN-F1   HN-F2   HN-F3
  y=0   RN-F0   RN-F1   RN-F2   RN-F3
        x=0     x=1     x=2     x=3
```

With `NodeID = (X << 7) | (Y << 3) | P` and every device on P0:

| | x=0 | x=1 | x=2 | x=3 |
|---|---:|---:|---:|---:|
| **y=3** | 0x018 | 0x098 | 0x118 | 0x198 |
| **y=2** | 0x010 | 0x090 | 0x110 | 0x190 |
| **y=1** | 0x008 | 0x088 | 0x108 | 0x188 |
| **y=0** | 0x000 | 0x080 | 0x100 | 0x180 |

### Latency

Per-stage budget, which is the M2 target and the thing M2 either confirms or
corrects here:

| stage | cycles | |
|---|---:|---|
| link | 1 | the transmitter's flit register |
| crosspoint | 2 | buffer the flit; arbitrate and drive the output |

A path of `H = |Δx| + |Δy|` hops costs `3H + 4` cycles: three to inject and
traverse the first crosspoint, three per hop after it, one to eject.

- adjacent devices on one crosspoint, `H = 0` — **4 cycles**
- corner to corner, `H = 6` — **22 cycles**
- mean over uniformly random pairs, `H = 2.5` — **11.5 cycles**

The mean hop count is `2(k²−1)/3k` for a `k × k` mesh, which is 2.5 at k = 4,
counting the src = dst pairs as zero hops.

### Throughput

Let λ be the flits per cycle each device injects, per channel class, and take
uniform-random destinations. Three separate things could bind first, and for
this topology all three bind at once:

- **Ejection.** Sixteen devices inject 16λ; sixteen device ports eject one flit
  a cycle each. → λ ≤ 1.
- **Bisection.** Cutting between x = 1 and x = 2 severs four links per
  direction. A quarter of all traffic crosses west to east, so 4λ over a
  capacity of 4. → λ ≤ 1.
- **The busiest link under XY.** The X link from (1,y) to (2,y) carries traffic
  from the 2 nodes west of the cut in row y to the 8 nodes east of it: 16 of the
  256 ordered pairs, so λ over a capacity of 1. The Y link from (x,1) to (x,2)
  works out the same by symmetry — 8 sources in the bottom half to the 2
  destinations in column x above the cut. → λ ≤ 1.

So the ideal saturation is **1.0 flit/cycle/device per class**, and the topology
offers no excuse: injection, ejection, bisection and the hottest link all
saturate together. Whatever M3 measures below that is the microarchitecture —
buffer depth, arbitration, credit return — and nothing else.

XY on a 4×4 spreads load better than it is usually given credit for: across all
forty-eight directed inter-crosspoint links only two loads occur, 12 and 16 of
the 256 ordered pairs, so the quietest link runs at three quarters of the
busiest. There is no hot link to design around at this size, which is worth
knowing before anyone proposes virtual channels to fix one.

Dimension-ordered routing with shallow input buffers does not reach 1.0 under
uniform random. M3 measures the real figure and records it here; the test
asserts a floor so that the number cannot quietly regress, and the floor starts
at **0.45** rather than at a guess dressed up as a requirement.

Populating P1 as well would double the devices without changing the mesh, and
the per-link bounds would halve relative to injection while the ejection bound
stayed put. That is a different reference topology and would get its own numbers.

## What checks this

```
bazel test //hardware/ip/chi_noc/...
```

Routing is checked exhaustively against the generator's model, combinationally,
with no simulation loop — the shape `//hardware/ip/common_cells/test` uses for
`cc_lzc`, and for the same reason: a truth table settles it and a waveform does
not. One crosspoint looped back on itself checks credits and ordering with no
mesh in the build; a generated mesh checks delivery, deadlock freedom and the
numbers above. Every assertion has a test that makes it fire, because an
assertion nobody has watched fail is decoration.

The generator's own tests need no simulator at all and run in seconds. A bug
should be caught by the cheapest layer that can see it.
