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

- [x] `chi_dpi.svh` / `chi_hn_dpi.cc`: one packed flit per call, a chandle per
      agent, and an elaboration-time check of the literal widths against
      `chi_pkg` -- an assertion rather than a generate `$error`, for the reason
      M3 records.
- [x] `chi::HomeNode`, simulator-free. One RN-F, so it never snoops. Reads,
      copyback and immediate writes, the dataless requests, `CompAck`,
      `WriteDataCancel`, and an error response for anything else rather than
      silence.
- [x] `SparseMemory` with watchpoints, `spdlog` behind `VIP_LOG_LEVEL`
- [x] The whole of a test's setup crosses DPI, so the testbench *is* the test:
      the program, the memory, the home node and the address that ends the run
      are all in `xs_cluster_tb.sv`, and its C++ is the one line every testbench
      shares.
- [x] `//hardware/soc/xs_cluster:xs_cluster` brings the trace-encoder port out
      rather than tying it off. It is the only window into what the core is
      doing that is not a waveform, and this milestone needed it.
- [x] **Gates passed.** `//hardware/vip/common/test:memory_test`;
      `//hardware/vip/chi/test:chi_home_node_test`, every opcode with no RTL in
      the build; and `chi_hn_agent_{read_line,write_word}_test`, the whole agent
      -- link, DPI, protocol model, memory -- against a request node's link with
      no design in the build. That last pair was not in the plan and should have
      been: it is the seam the other two cannot reach, and it is what proved the
      flit data reaching the core was correct.
- [x] `//hardware/soc/xs_cluster/tb:xs_cluster_tb_test`: the link comes up at
      cycle 199, the core asks for the line its reset vector is in at cycle
      1048, and the home node serves it. The thousand-cycle wait is CoupledL2
      walking its directory to clear it, not the core being slow.
- [x] **No C++ in any testbench directory.** Verilator's `--main` generates the
      `--timing` evaluation loop, and at 5.046 it generates precisely the one
      `sim_main.h` used to hand-write. Three `main()` files deleted; the
      `cc_test` targets carry no `srcs` at all. The verdict moved into the
      SystemVerilog with it -- a generated `main` always returns zero, so
      `vip_test_failed()` is a new DPI import and `$fatal` is what fails a run.
      Proved by planting a watchpoint that could not be satisfied and watching
      Exit 1 come back. What is left of `//hardware/vip/common:sim_main` is the
      `sc_time_stamp()` link stub, renamed `:verilated_shims`.

### Resolved: the core does not execute what it is served

**One field: CHI `DataCheck`.** The home node never wrote it, and CoupledL2
checks it. `RXDAT` in the generated RTL computes, for each of the thirty-two
bytes of a beat:

```systemverilog
corrupt |= DataCheck[i] ^ ~^data[8*i+7 : 8*i]
```

which is CHI's odd parity per byte. Leaving the field zero is not "not using
it" -- it asserts *even* parity for every byte, which is wrong for any byte
whose parity bit should be one, `0x00` among them. So `corrupt` was 1 from time
zero, every line the L2 was served was marked corrupt, TileLink carried
`d.corrupt` to the L1I, and the core raised a hardware-error exception
(`ExceptionNO 19`) on the first instruction it fetched. `mnstatus.NMIE` is zero
out of reset, so Smrnmi turned that trap into a critical error -- which is why
the symptom was `critical_error_o` at a fixed cycle whatever the program was.

The fix is `DataCheckOf()` in `//hardware/vip/chi/chi_home_node.cc`, three
lines. The run now ends the way it was always meant to:

```
xs_cluster_tb: CHI link running at cycle 199
xs_cluster_tb: the core fetched its reset vector at cycle 1048
[trace 1085] group 0: pc=00080000002 itype=0 iretire=8 priv=3
[vip] done: 0x20000000 was written 0x1
xs_cluster_tb: done at cycle 1120
```

**How it was found**, because the method generalises. Nothing about the symptom
pointed at the home node -- five earlier hypotheses had been eliminated by
changing the program, the reset length and the timer, and all that established
was that the core was not at fault. What found it was one FST of the failing run
and walking the corrupt bit backwards through the hierarchy:

| where | what |
|---|---|
| `NewCSR.io_fromRob_trap_valid` | one trap in the whole run, at pc `0x8000_0000` |
| `io_robio_exception_bits_exceptionVec_19` | hardware error, not a page fault or an access fault |
| `frontend.io_backend_cfVec_0_...` | it arrives *from the frontend*, with the fetched instruction |
| `icache.mainPipe.s1_tlCorrupt_r` | TileLink `d.corrupt` on the refill |
| `l2cache.slices_0.mshrCtl.mshrs_0.corrupt` | the L2 set it, and `denied` never fires |
| `mshrs_0.io_resps_rxdat_bits_corrupt` | **constant 1 from t=0** -- not an event, a stuck signal |
| `RXDAT.io_in_respInfo_corrupt` in the RTL | the parity expression above |

The step that mattered was the second-to-last, and it was nearly missed: a
search for "when does this rise" finds nothing on a signal that was never zero.

## M7 — Checking, properly

- [ ] The second CHIron tranche: `chi/xact/` as a transaction checker, `clog/`
      tracing behind a flag
- [ ] **Gate:** `chi_scoreboard_test`, legal and deliberately illegal sequences

## M8 — Proving the seams

- [ ] An AXI4 manager for the IMSIC port over the same `vip/common`. If it needs
      a change under `common/`, the layering was wrong.

## Review

_Filled in as milestones land._
