# A CHI NoC

Plan of record. The reasoning, the rejected alternatives and the risks live in
the plan document; this is the checklist.

Why: `hardware/soc/xs_cluster` speaks CHI Issue E.b out of one port and there is
nothing for it to speak to but a single home-node agent. What is missing is the
network — a mesh of crosspoints carrying CHI's four channel classes between an
arbitrary set of request, home and slave nodes, assembled from a topology
description and judged on throughput as well as correctness.

Scope is the **transport fabric only**. HN-F and SN-F stay external and are
played by verification IP; a real home node is a later programme that this one
has to finish first.

## M0 — the architecture document

- [x] Rebase onto `main`. PR #4 merged as `a10e0b1`, so `hardware/ip/chi` and
      `hardware/vip/chi` are available.
- [x] `.gitattributes` marking the vendored CHIron subset `rules-lint-ignored`,
      and the ten files PR #4 added that the pre-rebase formatter never saw,
      formatted. `bazel test //tools/format:format_test` green, and the 13 CHI
      and VIP tests still pass.
- [x] `hardware/ip/chi_noc/README.md` — NodeID encoding, channel-class
      independence as the deadlock argument, XY routing, the SNP fabric header,
      credit budgeting, and what throughput means here.
- [x] **Gate passed.** NodeID is 4/4/3 over the 11 bits `chi_pkg` declares, and
      the `mesh4x4` table gives all sixteen. Zero-load latency `3H + 4` cycles:
      4 adjacent, 22 corner to corner, 11.5 at the mean hop count of 2.5.
      Saturation bounds all coincide at 1.0 flit/cycle/device per class —
      ejection, bisection and the busiest directed link (16 of 256 ordered
      pairs) — so the topology gives the microarchitecture no excuse. Flit
      widths 162/73/422/115 agree with the `static_assert`s in
      `//hardware/vip/chi/chi_flit.h`.

## M1 — Python in this build, then `nocgen`

- [x] `aspect_rules_py` 2.0.0-alpha.6 with the uv extension; `pyproject.toml`
      and `uv.lock` at the root, plus `//:uv_lock` to refresh them and uv itself
      pinned by `uv_bin` rather than taken from the machine. The dependency
      group is a per-target `dep_group` attribute and **not** a `//.bazelrc`
      flag -- see tasks/lessons.md for what that cost.
- [x] Extend the comment on `rules_python` in `//MODULE.bazel`: it is LLVM's
      overlay dependency, not ours, and cannot be removed
- [x] `nocgen`: config model, graph, NodeID assignment, SAM, templates.
      **No pydantic** -- rules_py builds pydantic-core from source and then wants
      a Rust toolchain, so validation is plain dataclasses. See tasks/lessons.md.
- [x] Emits `<name>_noc.sv`, `<name>_noc_pkg.sv`, `<name>_noc.json`
- [x] `nocgen_topology()` macro, so a generated mesh is a build output.
      `//hardware/ip/chi_noc:mesh4x4` is the reference, generated in the graph.
- [x] **Gate passed.** 95 tests, no simulator, under a second: golden files for
      three examples; every ordered pair in each checked terminating, minimal and
      dimension-ordered; no path takes a forbidden turn; the SAM disjoint, even
      and line-granular; the manifest's routes identical to the model's; and the
      README's numbers (NodeIDs, 2.5 mean hops, 3H+4, 1.0 saturation, the 12/16
      link spread) asserted against the code that produces them.

- [x] Python is covered by the tooling: ruff pinned in
      //tools/multitool.lock.json, `ruff format` in //tools/format, `ruff check`
      and a 1 MiB file-size limit in //tools/checks, and all of it in
      tools/githooks/pre-commit. Each check watched failing before being
      believed.

## M2 — the crosspoint

- [x] Promote `chi_link_{tx,rx}_channel.sv` and
      `chi_link_activation_{req,ack}.sv` from `//hardware/vip/chi/rtl` to
      `//hardware/ip/chi`. The VIP keeps the two *role* modules and depends on
      the mechanism; all 11 of its tests still pass.
- [x] `cc_rr_arb_tree` in the common_cells overlay. `cc_stream_fifo` and
      `cc_onehot` turned out not to be needed: the receiver's buffer *is* its
      credit accounting, so `chi_link_rx_channel` already is the FIFO, and the
      destination mask is produced one-hot by construction.
- [x] `chi_noc_pkg.sv`, `chi_noc_flit_pkg.sv`, `chi_xp_channel.sv`, `chi_xp.sv`.
      Split into two packages so the CHI issue lives in one file and the switch
      can be built without a CHI package at all.
- [x] **Gate passed.** Routing exhaustively: all 524,288 (position, target) pairs
      agree with M1's model, including the NodeIDs that name a device port no
      crosspoint has, where both must answer *nowhere*.
- [x] **Gate passed.** One crosspoint looped back through its own link layer:
      every legal turn, ordering per (source, destination), all-to-all, and six
      inputs oversubscribing one output for eight times the credit count.
- [x] **Gate passed.** One negative test per assertion, each watched failing:
      an illegal turn, a flit addressed to no port, and an input starved past
      its bound.
- [x] **Gate passed.** One output stalled; the other five keep running and
      everything arrives once it is released.
- [x] Beyond the gates: `chi_xp_test` drives all four classes at once and checks
      for cross-talk and for the SNP fabric header surviving, and
      `--config=lint` now elaborates every generated topology against the real
      crosspoint — which is how the generator and the RTL are kept from drifting
      apart about a port list.

Found on the way, and recorded in the README: a crosspoint has **26** of the 36
turns, not 36 — four are missing because a flit arriving vertically may not leave
horizontally, six because nothing leaves the way it came. And arbitration is
**head-of-line**: a receiver exposes one flit at a time, so a blocked head blocks
what is behind it. That costs throughput, not correctness, and M3 is where the
cost gets measured rather than guessed at.

## M3 — the mesh, at flit level

- [x] The generated netlist takes an indexed device-port array rather than a
      port per device, with `<NAME>_INDEX` localparams, so a testbench can drive
      all sixteen the same way and integration stays explicit.
- [x] `nocgen` emits what a test needs to judge the mesh by: every device's
      NodeID in index order, the latency coefficients, and the saturation bound.
- [x] **Gate passed.** All 240 ordered device pairs deliver. `all_classes` also
      sends on RSP, DAT and SNP, which is what would catch a class miswired in a
      generated netlist rather than in the RTL.
- [x] **Gate passed.** 4096 flits of uniform random traffic drain; and drain
      again with every destination stalling at random one cycle in four.
- [x] **Gate passed, and it corrected M0.** Zero-load latency is `2H + 4`, not
      `3H + 4` — arbitration is combinational, so a crosspoint costs one cycle
      and not two. Checked for every ordered pair against the coefficients
      nocgen emits.
- [x] **Gate passed.** Four patterns measured at saturation: uniform 0.433,
      bit-complement 0.400, transpose 0.235, hotspot 0.053 flits/cycle/device.
      Each test asserts a floor just under its measurement, as a ratchet.

What the numbers say: hotspot reaches 85% of what a single destination port can
possibly eject, so the fabric is not the limit there. For the other three the
ceiling is 1.0 and the gap is **head-of-line blocking**, exactly as the README
predicted it would be — a receiver exposes one flit at a time. The remedy is a
receiver that can pop out of order; it is a change to `//hardware/ip/chi` and it
now has a number to be justified against rather than a suspicion.

Still open: `nocgen` computes the analytic bound for uniform traffic only, so
transpose and bit-complement are quoted against an upper bound rather than
against theirs.

## M4 — protocol level

- [x] `vip::chi::RequestNode` — the missing half of the VIP. A traffic generator
      and a checker at once: it queues work, turns it into requests as
      identifiers come free, and compares what comes back against what it
      believes memory holds. Flits in, flits out, no simulator.
- [x] Checked against the home node **with no RTL and no fabric** first
      (`chi_request_node_test`). If the two ends agree about CHI in isolation, a
      later failure with a mesh between them is the mesh's -- which is what makes
      the system test about the fabric.
- [x] `chi_noc_device_port` — how anything attaches to the mesh, and where the
      snoop's fabric header is put on and taken off.
- [x] The DPI pump extracted from `chi_hn_agent` into `chi_hn_core`, with
      `chi_rn_core` as its mirror. A crosspoint's device port is not a link, so
      flow control and the DPI boundary became separate modules; the cluster
      testbench is unchanged and still passes.
- [x] **Gate passed.** 264 transactions across the mesh -- eight requesters,
      four home nodes, reads, writes and dataless -- with every byte written
      landing where it was addressed. No mismatches, nothing unexpected, no
      unsupported request, and nothing outstanding at either end.

Two things worth keeping. The home node models no directory, so requesters own
disjoint address ranges and coherence between them is nobody's job here -- which
is the honest scope of a transport fabric, made true by partitioning rather than
assumed. And the workload is **phased**: a requester with eight transactions in
flight will happily issue a read of a line whose write is still outstanding, CHI
does not order those, and the read comes back as the memory fill byte. That
hazard is cache work, not fabric work.

## M5 — coverage

- [x] A monitor **bound** into `chi_xp_channel`, so the design carries no
      verification code and every instance is observed without anyone
      remembering to connect one. A bind's port list may name the target's
      internals, which is the only way to see decisions the switch never puts
      on a port.
- [x] Turn coverage: all 26 legal turns hit, all 10 illegal ones **empty** —
      the 26/10 split the README claims, now confirmed by counting rather than
      by argument.
- [x] N-way contention 1..5, and 6 required empty: a device output is the only
      one every other port can reach, and a port cannot ask for itself, so five
      is the most that can ever contend.
- [x] QoS: every `w >= l` pair hit, every `w < l` pair **empty**. That second
      half is the direct statement that a lower-priority flit never beat a
      higher-priority one to an output, which nothing else checks.
- [x] Backpressure reached an input.
- [x] **Gate passed**, and both halves watched failing: removing the QoS
      stimulus names the empty bins; a count planted in a forbidden bin fires
      with the turn named.

Not binned, deliberately, and argued where the bins are: per-channel-class
turns (the switch cannot tell which class it is, so four sets would be four
copies of one piece of evidence — `chi_xp_test` and `all_classes` cover the
wiring); every turn in every crosspoint of a mesh (SystemVerilog cannot index a
hierarchical name, and `all_pairs` answers the question better by delivering
down all 240 paths); and credit exhaustion and link activation, which are
link-layer properties with their own tests in `//hardware/vip/chi/test`.

Credit and activation are worth being explicit about: the fabric ties its links
to RUN by design, so those bins **cannot** be reached here. A bin that is
unreachable by construction does not belong in a list of bins that must be hit.

## M6 — a topology that is not a mesh *(stretch)*

- [ ] Ring, one irregular topology, and table-driven routing

## Where this stands

M0 through M5 are done. A CHI transport fabric exists, is generated from a
description, and is verified at five layers: the routing function against a
model exhaustively, one crosspoint against itself, a mesh at flit level, real
CHI transactions across it, and a coverage list that says the cases were the
right ones.

What the numbers are, all measured rather than budgeted:

| | |
|---|---|
| zero-load latency | `2H + 4` cycles, every ordered pair |
| uncontended throughput | 1.000 flit/cycle/device |
| uniform random | 0.603 |
| bit-complement / transpose / hotspot | 0.500 / 0.286 / 0.066 |
| transactions across the mesh | 264, no mismatches |

Three of those numbers contradicted what M0 predicted, and the predictions were
wrong in ways worth remembering: latency was budgeted a cycle per hop too slow,
the throughput floor was guessed before measuring, and the credit count was set
from a comment rather than a measurement — costing 20% of the bandwidth of every
link in the fabric until a control with no contention in it exposed it.

### Open, in the order it is probably worth doing

1. **Head-of-line blocking.** Uniform sits at 0.603 against a ceiling of 1.0,
   close to the classic input-queued FIFO bound of `2 - sqrt(2)`. The remedy is
   a receiver that can pop past a blocked head; the hazard is that two flits
   from one input to the same output must not be reordered, and
   `chi_noc_mesh_all_pairs_test` plus the per-pair ordering check is the safety
   net it would need. A change to `//hardware/ip/chi`, shared with the VIP.
2. **`chi_sam.sv`.** The System Address Map is a function in the system
   testbench today. It belongs in RTL, and `chi_noc_system_tb`'s `home_for` is
   what it has to agree with.
3. **A pattern-aware analytic bound.** `nocgen` computes the network bound for
   uniform traffic only, so transpose and bit-complement are quoted against an
   upper bound rather than theirs. The link-load model already there can do it.
4. **M6**, below: a ring, an irregular topology, and table-driven routing.
5. **A real HN-F** — snoop filter, MSHRs, SLC. The separate programme this one
   had to finish first, and the reason the fabric was kept to transport.