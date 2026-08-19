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

- [x] `//hardware/ip/chi/src/chi_pkg.sv`: widths, `chi_issue_e`, the four
      opcode enums, `chi_resp_e` / `chi_resp_err_e` / `chi_order_e`,
      `chi_mem_attr_t`, `chi_mpam_t`, `chi_link_state_e`, the snoop and DAT
      classifiers. Values from ARM IHI 0050 (Issue H, whose shared encodings
      have not moved); membership from CHIron's E.b tables, since Issue H
      defines a good many opcodes E.b does not.
- [x] `include/chi_typedef.svh`: `CHI_TYPEDEF_{REQ,RSP,DAT,SNP}_T`,
      `CHI_TYPEDEF_FIELDS`, `CHI_TYPEDEF_ALL`
- [x] Credit-based link bundles, which `hw.riscv#2184` does not have: its
      bundles are valid/ready, and a CHI link is not. `chi_rn_link_tx_t` and
      `chi_rn_link_rx_t`, one packed struct per direction.
- [x] **Gate passed.** `chi_pkg_test`: 588 checks, including every encoding of
      all four opcode spaces -- 128, 32, 32 and 16 -- compared against CHIron
      by name in both directions, so an opcode invented here and one forgotten
      fail the same way. `chi_layout_test`: 74 fields across four channels,
      the package packing and CHIron decoding.
- [x] The testbenches are SystemVerilog driving C++ over DPI, which is the
      shape M6 needs anyway. Each declares only the imports it implements:
      Verilator emits a wrapper for every `import "DPI-C"` it parses, so a
      shared header of all of them is a link error in whichever testbench uses
      the smaller half.

## M3 — `xs_cluster.sv` on struct ports

- [x] CHI ports become `chi_pkg::chi_rn_link_tx_t` and `chi_rn_link_rx_t`;
      thirty signals become two, and the mapping to the generated top's flat
      ports moves inside
- [x] Rewrite the comment claiming a CHI package "belongs with the
      interconnect" -- no longer true, and it would mislead
- [x] The width check does **not** live in the wrapper. `$error` in a generate
      block is `%Warning-USERERROR` to Verilator, so that check passes whatever
      the widths are; proved by writing it with a false condition and watching
      lint succeed. XSTop's four literal widths went into `chi_pkg_test`
      instead, where a wrong one fails -- also proved, the other way round.
- [x] **Gate passed.** `bazel build --config=lint //hardware/...` elaborates the
      wrapper with the struct ports and reports no width warning on any CHI
      connection.

## M4 — Verilate the cluster

- [x] `xs_cluster_tb.sv`: clock process, reset, DUT, IMSIC tied off, mtime
      counter, timeout
- [x] `verilator_cc_library(timing = True)`, `--output-split 20000`,
      `--timescale 1ns/1ps`
- [x] `//hardware/vip/common:sim_main`, the `--timing` loop every testbench here
      shares. Its deadlock detector found its own bug on the first run:
      `gotFinish()` has to be tested immediately after `eval()`, because
      `$finish` leaves nothing scheduled and the other order calls every
      successful run a hang.
- [x] **Gate passed.** 676 s and 8187 actions to build; the model runs 1000
      cycles in 12 s. The cluster comes out of reset, raises
      `tx_linkactivereq`, and `critical_error_o` stays low.
- [x] One scare, and it was ours: `%Error-DIDNOTCONVERGE` from
      `forever #(ClkPeriod / 2)`, where `time` is an integer type and the
      division rounded to zero. `--timing` on 1868 generated modules is fine.

## M5 — The link layer, in SystemVerilog

- [x] `chi_link_tx_channel.sv` and `chi_link_rx_channel.sv`: one channel each
      way, parameterised by flit width so one module serves all four channels.
      Credits, the buffer they promise, `LCrdReturn` filtering, and the
      invariants as `$fatal` assertions.
- [x] `chi_link_activation_req.sv` / `_ack.sv`: the LINKACTIVE handshake, split
      by role rather than parameterised by it.
- [x] `chi_link_hn.sv` and `chi_link_rn.sv`: three channels each way, the two
      handshakes, `syscoreq`/`syscoack`, the sactive pair.
- [x] Deactivation returns unspent credits as `LCrdReturn` flits. Written
      because the test for it hung: a receiver may not withdraw its
      acknowledgement while it is still owed credits, so without this the link
      reaches DEACTIVATE and stops there.
- [x] **Gate passed.** Seven tests over one loopback model with no XiangShan in
      the build: `bringup`, `transfer` (six flits, six channels, payloads
      compared), `credit` (four flits on four credits, then a stall, then
      resumption), `deactivate`, and two negative cases that drive the pins
      directly and must trip a named assertion. `expect_failure.sh` takes the
      expected message, because the first version of the overrun case passed on
      an unrelated assertion in a different module.

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
