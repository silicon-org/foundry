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

- [ ] Promote `chi_link_{tx,rx}_channel.sv` and
      `chi_link_activation_{req,ack}.sv` from `//hardware/vip/chi/rtl` to
      `//hardware/ip/chi`
- [ ] `cc_rr_arb_tree`, `cc_stream_fifo`, `cc_onehot` in the common_cells overlay
- [ ] `chi_noc_pkg.sv`, `chi_xp_channel.sv`, `chi_xp.sv`
- [ ] **Gate:** routing exhaustively, against M1's model
- [ ] **Gate:** one XP looped back — credits exact, no loss, no reorder
- [ ] **Gate:** one negative test per assertion
- [ ] **Gate:** backpressure on one output does not block the other five

## M3 — the mesh, at flit level

- [ ] **Gate:** all-to-all correctness, every ordered pair, all four classes
- [ ] **Gate:** no deadlock under saturation with stalling receivers; drains
- [ ] **Gate:** throughput and zero-load latency against M0's numbers
- [ ] **Gate:** transpose, bit-complement and hotspot

## M4 — protocol level

- [ ] `chi_rn_agent` — the missing half of the VIP
- [ ] **Gate:** real transactions across the fabric; `unsupported` and
      `Outstanding()` both zero; memory matches

## M5 — coverage

- [ ] Turn coverage per XP per class, with the illegal turns required *empty*
- [ ] Credit counters at 0 and at maximum
- [ ] QoS class against QoS class; N-way contention for N = 2..6
- [ ] Activation and deactivation crossed with in-flight traffic
- [ ] **Gate:** a test that fails on any empty required bin

## M6 — a topology that is not a mesh *(stretch)*

- [ ] Ring, one irregular topology, and table-driven routing
