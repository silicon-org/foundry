# Verification IP

Reusable agents for the bus protocols this project's blocks speak. CHI today;
AXI and TileLink on the same skeleton.

The organising idea is one sentence: **the interface is separate from the
protocol.** Moving a flit across a link and deciding what a `ReadNotSharedDirty`
means are different problems, they change for different reasons, and the second
one is worth a great deal more than the first. Splitting them is what makes an
agent reusable rather than a testbench somebody wrote once.

## The four layers

```
  hardware/soc/<design>/tb/*.sv        clock, reset, DUT, program image, $finish
        │
        │  the only <design>-specific code
        ▼
  hardware/vip/<protocol>/rtl/*.sv     THE INTERFACE
        │  flow control and nothing else: credits or valid/ready, link bring-up,
        │  flit or beat registers. Reads no opcode. Synthesisable in shape, so
        │  the same module can front real RTL later.
        ▼
  hardware/vip/<protocol>/dpi/*.svh    THE BOUNDARY
        │  one packed flit or beat per call, and a chandle per agent instance.
        ▼
  hardware/vip/<protocol>/*.h,*.cc     THE PROTOCOL
        │  transactions, cache states, ordering, responses. No wires, no
        │  simulator, no Verilator header. Unit-testable on its own.
        ▼
  hardware/vip/common/                 SHARED BY EVERY PROTOCOL
           MemoryBackend, SparseMemory, Watchpoint, Scoreboard, logging
```

Two properties fall out of that shape, and both are worth more than they cost.

**The C++ is simulator-independent.** It talks DPI, not Verilator, so the same
agent runs under a commercial simulator without a line changing. The testbench
top is ordinary SystemVerilog with a clock generator, which is also why
`--timing` is on.

**The protocol layer is testable without RTL.** A home node is a function from
flits to flits; the test that covers every opcode it supports needs no
simulator, builds in seconds, and is where a bug should be caught. The
1868-module cluster testbench is the last line, not the first.

## Adding a protocol

1. `rtl/<p>_link_<role>.sv` — flow control for one end of the link, and its
   mirror for the other, so the pair can be tested against each other with no
   DUT in the build.
2. `rtl/<p>_checker.sv` — the interface rules as assertions. Immediate
   assertions in clocked `always` blocks rather than concurrent SVA, because
   Verilator supports a subset of the latter and this has to run here first.
3. `dpi/<p>_dpi.svh` + `.cc` — the boundary. DPI import declarations cannot be
   parameterised, so widths are literals there and an elaboration-time `$error`
   catches a disagreement with the package.
4. `<p>_<role>.h/.cc` — the protocol model, over `common/`'s `MemoryBackend`.
5. Tests, at every layer. See below.

If step 4 or 5 needs a change under `common/`, the layering is wrong somewhere
and that is the thing to fix.

## Testing

Every layer is tested at that layer, and each has its own Bazel target:

| | |
|---|---|
| Flit or beat encoding | field positions against a table written from the specification, then a round trip |
| Interface | the two link ends looped back, with no DUT: bring-up, credit exhaustion, teardown |
| Checkers | one negative test per assertion, injecting the violation and requiring it to fire |
| Protocol | the model on its own, one case per opcode, no simulator |
| System | the real DUT, once the four above are green |

An assertion nobody has watched fail is decoration, which is why the third row
is not optional.

```
bazel test //hardware/vip/...          # everything except the system tests
```

## What is here

| Path | |
|---|---|
| `common/` | protocol-agnostic: the memory model, watchpoints, the scoreboard, logging, the generic `--timing` main loop |
| `chi/` | CHI-E.b. `chiron/` is a vendored subset of [CHIron](https://github.com/RISMicroDevices/CHIron) supplying the flit layouts and their pack/unpack; everything else is ours |
