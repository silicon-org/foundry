# A CHI home-node agent, and a testbench that boots the XiangShan cluster

Plan of record. Full reasoning and risks live in the plan document; this is the
checklist.

Why: nothing in this repository drives `//hardware/soc/xs_cluster`'s CHI port,
so the design has never been elaborated by anything but the lint aspect and the
core has never fetched an instruction here. The immediate goal is a `while (1)`
nop loop executing out of a memory on the far side of the link. The lasting goal
is agents where the *interface* is separate from the *coherence protocol*, so
the same harness serves CHI now, AXI next -- the IMSIC AXI4 slave is already
there and unconnected -- and TileLink when Spatz clusters arrive.

Shape: a pure SystemVerilog testbench under `--timing`, an SV link layer that
knows no opcode, a DPI boundary carrying one packed flit per call, and a
simulator-free C++ protocol model. See `//hardware/vip/README.md`.

## M0 — C++20 everywhere

- [x] `--cxxopt=-std=c++20` and `--host_cxxopt` in `//.bazelrc`. Needed three
      times over: Verilator's `--timing` runtime is coroutines and
      rules_verilator already forces `-std=c++20` on the generated model;
      CHIron is concepts and `consteval`; and it settles what `tasks/todo.md`
      left open at M5 of the CIRCT work.
- [x] **Gate passed.** `bazel build @circt//:firtool` — 1883 actions, 283s, LLVM
      and MLIR rebuilt at C++20 with no source changes anywhere.

## M1 — CHIron, vendored

- [x] The subset, at commit `1581e237`: 17 headers, 700 KB, against 13 MB
      upstream. `chi/{basic,spec,util}`, `chi_eb/{spec,util}`,
      `common/{nonstdint,utility}.hpp`. Derived with `clang++ -H` rather than by
      reading includes, because CHIron includes headers textually more than once
      under different issue macros and the graph is not obvious.
- [x] `PROVENANCE.md` and `refresh.sh`, so a bump is a reviewable diff, and the
      exception recorded in `//hardware/README.md`.
- [x] `chi_flit.h`: `FlitConfiguration<11, 48, 4, 4, 256, true, true, true>`,
      the four width assertions, and `Pack`/`Unpack`.
- [x] **Two upstream bugs found and patched**, both in `chi_util_flit.hpp`:
      - `0001` — `FlitAppender::Append32` never advances `offset` for a field
        that does not cross a word boundary, advances `index` twice for one
        that does, and shifts by 32 when a field ends on a boundary.
        `Serialize*` has therefore never worked; its own assertion fires on the
        first flit. Only deserialization was ever exercised upstream.
      - `0002` — `DeserializeREQ` and `DeserializeSNP` drop the top of `Addr`:
        the second half is OR-ed in with no `<< 32`, so `0xabcdef012345`
        decodes as `0xef01abcd`. Every other multi-word read in the file has
        the shift. All twelve now go through one sequenced `Walk64` helper,
        which also removes the unsequenced `|` the others shared.
      Both worth sending upstream.
- [x] **Gate passed.** `//hardware/vip/chi/test:chi_flit_test` — 162/73/422/115
      as `static_assert`s, 67 field positions checked one at a time against a
      table written from the specification, four round trips, and the
      LPID/TagGroupID aliasing pinned down.

## M2 — The CHI package

- [ ] `//hardware/ip/chi/src/chi_pkg.sv`: widths, `chi_issue_e`, the four
      opcode enums, `chi_resp_e` / `chi_resp_err_e` / `chi_order_e`,
      `chi_mem_attr_t`, `chi_mpam_t`, the snoop and DAT classifiers
- [ ] `include/chi_typedef.svh`: `CHI_TYPEDEF_{REQ,RSP,DAT,SNP}_T`,
      `CHI_TYPEDEF_FIELDS`, `CHI_TYPEDEF_ALL`
- [ ] Credit-based link bundles, which `hw.riscv#2184` does not have: its
      bundles are valid/ready, and a CHI link is not. One packed struct per
      direction, so two ports replace thirty on `xs_cluster`.
- [ ] **Gate:** `//hardware/ip/chi/test:chi_pkg_test` (`$bits`, classifiers
      exhaustively) and `:chi_layout_test` (the SV struct against CHIron, both
      directions)

## M3 — `xs_cluster.sv` on struct ports

- [ ] CHI ports become the link bundles; the packing to the generated top's
      flat signals moves inside
- [ ] Rewrite the comment claiming a CHI package "belongs with the
      interconnect" -- it is no longer true and would mislead
- [ ] **Gate:** `bazel build --config=lint //hardware/...`

## M4 — Verilate the cluster

- [ ] `xs_cluster_tb.sv`: clock process, reset, DUT, IMSIC tied off, timeout
- [ ] `verilator_cc_library(timing = True)`, `--output-split`, fst behind a flag
- [ ] `//hardware/vip/common:sim_main.cc`, shared by every testbench here
- [ ] **Gate:** `//hardware/soc/xs_cluster/tb:xs_cluster_tb` as a reset-only
      smoke test, growing into the real one at M6. Record the wall clock.

## M5 — The link layer, in SystemVerilog

- [ ] `chi_link_hn.sv`, `chi_link_rn.sv`, `chi_checker.sv`
- [ ] **Gate:** `chi_link_{bringup,credit,deactivate}_test` over a loopback with
      no XiangShan, and `chi_link_checker_test` injecting one violation per
      assertion

## M6 — The DPI boundary and the home node

- [ ] `chi_dpi.svh` with an elaboration-time width check against the package
- [ ] `chi::HomeNode`, simulator-free. One RN-F, so it never snoops.
- [ ] `SparseMemory`, `Watchpoint`, spdlog
- [ ] The program as words: nops, `sw` to `tohost`, `j .`
- [ ] **Gate:** `//hardware/vip/common:memory_test`,
      `//hardware/vip/chi:chi_home_node_test` (every opcode, no RTL), then
      `xs_cluster_tb`

## M7 — Checking, properly

- [ ] The second CHIron tranche: `chi/xact/` as a transaction checker, `clog/`
      tracing behind a flag
- [ ] **Gate:** `chi_scoreboard_test`, legal and deliberately illegal sequences

## M8 — Proving the seams

- [ ] An AXI4 manager for the IMSIC port over the same `vip/common`. If it needs
      a change under `common/`, the layering was wrong.

## Review

_Filled in as milestones land._
