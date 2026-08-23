# CHI NoC

A mesh of crosspoints that carries CHI between request, home and slave nodes.

```
src/chi_noc_pkg.sv          ports, NodeID layout, routing. No CHI dependency.
src/chi_noc_flit_pkg.sv     the flits, and the five numbers. The CHI issue lives here.
src/chi_xp_input_buffer.sv  credits, a payload memory, and a queue per output
src/chi_xp_channel.sv       one channel class through one crosspoint
src/chi_xp.sv               four channel classes = one crosspoint
src/chi_noc_device_port.sv  how a device attaches, and the snoop's fabric header
src/chi_sam.sv           address -> home node (M3)
nocgen/                  the generator that wires crosspoints into a topology
test/                    routing against the model; the switch against itself
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
no cycle because the turns that would close one do not exist.

So a crosspoint has 26 of the 36 turns, not 36. Four are missing because a flit
that arrived vertically may not leave horizontally, and six because nothing may
leave by the port it arrived on -- that is a node addressing itself, or two
nodes sharing a NodeID. `chi_noc_pkg::chi_xp_turn_legal` is the one statement of
which is which, used by the assertion, by the tests and by M5's coverage.

That invariant is checked three ways: `chi_xp_channel` asserts on it,
`//hardware/ip/chi_noc/test` drives each kind of illegal turn and requires the
assertion to fire, and M5 requires the corresponding coverage bins to stay
**empty**. A turn that is illegal and never exercised and a turn that is illegal
and quietly taken look identical in a report that only counts what happened.

Table-driven routing, for topologies that are not meshes, is M6 and changes only
the route function.

## The crosspoint

Six ports — East, West, North, South, P0, P1 — of which the four compass ports
connect to neighbours and the two device ports to whatever the topology hangs
there. An edge crosspoint simply has ports disabled, which removes their logic
rather than tying them off.

Each output is a `chi_link_tx_channel` from `//hardware/ip/chi`. Each *input*
is a `chi_xp_input_buffer`, and its shape is where the interesting decision is.

A flit arriving at an input is split in two. Its **payload** — all 422 bits of a
DAT flit — goes into a memory with one write port and one read port whose output
is registered, which is what an SRAM is. Its **routing information** — which
output, and how urgently — is used once to choose a queue and then lives in a
flop array a fraction of the size.

That split is what makes looking past a blocked flit affordable. The obvious way
to do it, letting the arbiter consider every buffered entry, costs
`Credits × Ports` candidates per output and an O(Credits²) check that no older
entry in the same buffer is going to the same place. Linking the entries into
**one queue per output** instead means each output arbitrates over six queue
heads — exactly as many as a single FIFO offered — and per-(input, output) order
is kept by the queue rather than by a comparison. Everything the scheduler reads
is eighteen bits per input: six queue-valid bits and six priorities.

Deciding what moves is then a bipartite match between six inputs and six
outputs, because a payload memory has one read port and an input can send one
flit per cycle. Each pass has every free output pick a free input, highest QoS
class first, and then every free input accept one of the outputs that picked it.
**Three passes**, and the number is measured rather than chosen: one pass leaves
an output idle whenever several pick the same input, and that loss more than
cancelled what the queues had bought — 0.533 against the FIFO's 0.603. Two
recovered it, three settled it, four changed nothing.

The credit check belongs in *eligibility* and not in the final grant. An output
with no credit that can still be picked consumes its input's one slot for the
cycle, and head-of-line blocking reappears one level up.

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

It does not name a struct and does not know which channel class it is.
Everything else it needs — that opcode zero is an L-Credit return — is answered
on its behalf by `chi_pkg::chi_*_is_lcrd_return` and handed in as a bit per port.

Opcode zero is worth dwelling on, because it is the one place a CHI rule reaches
into an otherwise protocol-blind switch: **a flit whose opcode is zero is flow
control, not a message**, on every channel. A testbench that builds a flit by
setting the fields it cares about and leaving the rest at zero has built an
L-Credit return, and the crosspoint is right to consume it and send nothing on.

`chi_noc_flit_pkg.sv` computes those numbers from the `chi_pkg` typedefs and is
the **only file in the fabric that depends on the CHI issue.** `chi_noc_pkg` --
ports, NodeID, routing -- has no CHI dependency at all, which is what lets the
switch be built and tested without one. At the reference configuration the
numbers come out as:

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
the receiver grants them by pulsing LCRDV, and there is no ready anywhere. So a
channel runs at line rate only if the transmitter holds at least as many credits
as the round trip takes to return one, and at `credits / round-trip` of line rate
otherwise.

**The round trip is five cycles.** Measured, by driving a permutation in which
every input has exactly one destination and no two streams share a directed link
— nothing contends with anything, so whatever that reaches is what the fabric
can do unobstructed. It reaches `min(1, Credits/5)` exactly: four credits give
80.0%, five give 100.0%, and no amount of extra depth moves it.

The default is **ten**, and it is a measured peak rather than a round number.
Six was one more than the round-trip floor and enough while each input was a
single FIFO; per-output queues split the same pool between them, so the
bottleneck flow gets fewer slots and the pool has to be larger. Six cost
bit-complement a fifth of its throughput, eight restored it, and ten is where
uniform stops improving. See the throughput table. The round trip is a property of
the current pipeline, and if a register is ever added to the credit path five
would quietly drop back under line rate — the symptom being a fifth of the
bandwidth missing, with nothing failing. The specification caps a receiver at 15
outstanding (`chi_pkg::CHI_MAX_LCREDITS`), and exceeding it means the receiver is
broken rather than generous, which the existing assertion says.

This paragraph used to say four credits sufficed because "a credit takes three
cycles to come back". That was a budget read off a block diagram, and it cost
20% of the fabric's bandwidth on every link in it, contended or not. The lesson
is not about credits: **a number that determines throughput should be measured
before it is defaulted**, and a permutation with no contention in it is a cheap
way to measure this one.

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

**Measured**, by driving every ordered pair through an otherwise empty mesh:
`3H + 5` cycles for a path of `H = |Δx| + |Δy|` hops.

Every register on the path costs a cycle and nothing else costs anything,
because routing, the match and the crossbar are all combinational. There are
three registers per hop:

| stage | cycles | |
|---|---:|---|
| receiver | 1 | the write into the buffer the credit paid for |
| payload memory | 1 | its registered output, because it is an SRAM |
| transmitter | 1 | the flit register on the way out of a port |

A path crosses `H + 1` crosspoints holding two each, and `H + 2` links holding
one each — the two extra links being the device's own: `3(H + 1) + 2`.

- two devices on one crosspoint, `H = 0` — **5 cycles**
- corner to corner, `H = 6` — **23 cycles**
- mean over uniformly random pairs, `H = 2.5` — **13 cycles**

The mean hop count is `2(k²−1)/3k` for a `k × k` mesh, which is 2.5 at k = 4,
counting the src = dst pairs as zero hops.

This number has been wrong twice, in both directions. It first said `3H + 4`, on
the reasoning that a crosspoint spends a cycle buffering and a second
arbitrating — it does not, arbitration is combinational, and the answer was
`2H + 4`. Then the payload memory's output was registered, as an SRAM's is, and
a crosspoint really did come to cost two cycles. **That is the price of the
throughput below**, and it is paid on every hop whether the fabric is busy or
not: 16 cycles corner to corner became 23.

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

Measured at saturation, with 1024 flits from each of the sixteen devices and ten
credits per port. Each pattern is quoted against **its own** ceiling: the lower
of what its busiest link can carry and what its destinations can eject.

| pattern | flits/cycle/device | its ceiling | of ceiling | was, with one FIFO |
|---|---:|---:|---:|---:|
| no-contention control | **1.000** | 1.000 | **100%** | 1.000 |
| uniform | **0.759** | 1.000 | 76% | 0.603 |
| bit-complement | **0.500** | 0.500 | **100%** | 0.500 |
| transpose | **0.333** | 0.333 | **100%** | 0.286 |
| hotspot | **0.066** | 0.125 | 53% | 0.066 |

Three of the five run at exactly their theoretical maximum. That is worth saying
plainly, because this table used to quote every pattern against the *uniform*
bound — which made a fabric at 100% of what a permutation allows look like one
managing a third of what it should. A permutation pins every flow to one path,
so its busiest link's share is computable, and `chi_noc_mesh_tb` now computes
it rather than borrowing a number that was never theirs.

Uniform is where head-of-line blocking lived, and per-output queues took it from
0.603 to 0.759. The FIFO could not be helped by depth — it sat at the classic
input-queued bound of `2 − √2 ≈ 0.586` whatever the buffer, 0.599 at ten
credits. Queues keep responding to depth, and **that is the argument for the
payload being an SRAM**: the fix wants entries, and entries are what make
422-bit storage cost something.

Hotspot is at 53% of a ceiling set by two destination ports; its 212-cycle mean
latency is the queue in front of them and not anything the fabric does.

### What is left, and what it would take

**Uniform is the only pattern with anything on the table**, and it is also the
only one with variance — it redraws a destination per flit, so a link's
instantaneous demand fluctuates about its mean. Reaching 1.000 means never
leaving the sixteen busiest links idle, and with random arrivals and finite
buffers that cannot be done: throughput approaches capacity only as buffering,
and therefore delay, grow without bound. The measured curve is exactly that
trade.

| credits | uniform | mean latency |
|---:|---:|---:|
| 6 | 0.652 | 20 |
| 8 | 0.694 | 25 |
| **10** | **0.759** | 30 |
| 12 | 0.745 | 35 |
| 15 | 0.730 | 42 |

Ten is the peak; past it latency grows and throughput does not. Matching is not
the constraint either — three passes reaches 0.759, and four, six and more reach
the same number, so the schedule is already maximal.

So both of the cheap knobs are exhausted, and the last quarter needs a different
machine rather than a bigger one:

- **Internal speedup** is the standard answer. A crossbar that moves more than
  one flit per port per cycle decouples the match from the link, and a speedup
  of two is enough to emulate output queueing exactly. It costs a second read
  port on every payload memory and twice the internal bandwidth.
- **Output queues** are the cheaper half of that: a few entries after the
  crossbar absorb the variance that leaves a link idle, without doubling
  anything. Less benefit, much less cost.
- **Load balancing** would matter above about 0.84 and not below it. XY leaves
  the sixteen busiest links carrying 19% more than the average, so they saturate
  first; spreading that needs XY and YX in the same network, which needs two
  virtual channels to stay deadlock-free. At 0.759 no link is saturated, so this
  buys nothing yet.

The tests assert a floor a little under each measurement. They are a **ratchet
against regression, not a specification** — raising one when the design improves
is the point of having it.

Populating P1 as well would double the devices without changing the mesh, and
the per-link bounds would halve relative to injection while the ejection bound
stayed put. That is a different reference topology and would get its own numbers.

## What checks this

```
bazel test //hardware/ip/chi_noc/...
```

Routing is checked exhaustively against the generator's model — all 524,288
(position, target) pairs the NodeID layout can express, combinationally, with no
simulation loop. That is the shape `//hardware/ip/common_cells/test` uses for
`cc_lzc` and for the same reason: a truth table settles it and a waveform does
not. It includes the targets that name a device port no crosspoint has, where
both statements must agree that the answer is *nowhere*.

One crosspoint with its ports looped back on itself covers the rest: every legal
turn, ordering per source and destination, six inputs oversubscribing one output
for many times the credit count, and one output stalled while the other five keep
running. Each of the three assertions has a test that makes it fire — an illegal
turn, a flit addressed to no port, and an input starved past its bound — because
an assertion nobody has watched fail is decoration.

Then the mesh, which is where the questions that need a network get asked: every
one of the 240 ordered device pairs delivers; zero-load latency matches `2H + 4`
for each of them; 4096 flits of uniform random traffic drain, and drain again
with every destination stalling at random; and the four traffic patterns above
are measured rather than assumed. A fabric that deadlocks does not drain, so the
watchdog is the verdict and the flit count is the evidence.

`bazel build --config=lint //hardware/...` elaborates every generated topology
against the real crosspoint, which is what catches the generator and the RTL
drifting apart about a port list. A golden-file test cannot see that: both sides
of it are generated from the same description.

And the protocol, once there is something to speak it: eight request nodes and
four home nodes attached through device ports, running reads, writes and
dataless requests across the mesh, with every byte written checked to have
landed where it was addressed. The two models are checked against *each other*
first, with no simulator at all, so a failure with the mesh between them is the
mesh's.

The generator's own tests need no simulator and run in seconds. A bug should be
caught by the cheapest layer that can see it.

## What says the tests are enough

A suite that passes proves the cases in it work. What says the cases were the
right ones is a set of bins, collected by a monitor **bound** into
`chi_xp_channel` so the design carries no verification code, and checked in one
run by `chi_xp_channel_coverage_test`:

| bin | required |
|---|---|
| turn `[in][out]` | all 26 legal turns hit; all 10 illegal ones **empty** |
| contention `[n]` | a grant taken with 1..5 inputs asking; 6 **empty** |
| `qos_win[w][l]` | every `w ≥ l` hit; every `w < l` **empty** |
| `stalled[p]` | an input held a flit it could not place |

The empty half is the half worth having. A turn that is illegal and never taken
and a turn that is illegal and quietly taken look identical in a report that
only counts what happened — and `qos_win[w][l]` for `w < l` is the direct
statement that a lower-priority flit never beat a higher-priority one to an
output, which no other check makes.

Both halves have been watched failing: removing the QoS stimulus names the empty
bins, and a count planted in a forbidden one fires with the turn named.

Three things are deliberately not binned, and the file says so where the bins
are: per-channel-class turns, because the switch cannot tell which class it is
and four copies of one piece of evidence is not four pieces; every turn in every
crosspoint of a mesh, because whether every path works is what
`chi_noc_mesh_all_pairs_test` establishes directly over all 240 of them; and
L-Credit exhaustion and link activation, which belong to the link layer and are
driven against it by `//hardware/vip/chi/test`. A bin that cannot be reached by
construction should not sit in a list of bins that must be.
