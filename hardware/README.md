# Hardware

Designs, and the third-party IP they build on.

```
hardware/
  ip/           third-party IP, integrated but not vendored
    common_cells/
    xiangshan/   a generator rather than RTL; see below
```

## How third-party IP is integrated

Sources are **not** copied into this repository. Each IP is fetched by an
`http_archive` in `//MODULE.bazel`, pinned by sha256, and the BUILD file that
turns it into Bazel targets lives here under `ip/<name>/`.

That split matters. The upstream sources stay upstream's, at a version anyone
can verify; the description of how we build them is ours, reviewed like any
other code. Aliases in `ip/<name>/BUILD.bazel` mean the rest of the repository
refers to `//hardware/ip/common_cells:cc_lzc` rather than to an external repo
label, so the integration is visible in the label.

Only what is actually used gets a target. Adding a cell should be a decision
someone made, not a side effect of a glob.

## When the IP is a generator

XiangShan is written in Chisel, so upstream ships no RTL at all — what it
publishes is a Scala program that prints SystemVerilog. Pinning generated RTL
would mean pinning somebody's build output and taking on faith that it came from
the commit it claims to; so what is pinned is the generator, and the RTL is
produced by an action in this graph like any object file.

Chisel is a library, not a build system. mill is what upstream drives it with,
and mill is not part of the design — so `//hardware/ip/xiangshan` reproduces the
module graph from upstream's `build.mill` as `scala_library` targets and never
runs mill. Every jar comes from a lock file, the Scala compiler is pinned by
rules_scala, and `firtool` — the CIRCT binary Chisel emits SystemVerilog through
— is pinned at the version Chisel's own `etc/circt.json` names.

```
bazel build //hardware/ip/xiangshan:xsnoctop_verilog
```

The result is 139 MB of SystemVerilog holding one core, its L2, its IMSIC and a
CHI port, and from there it is source like anything written by hand.

Three consequences worth knowing before relying on it:

- Generation is one JVM action that elaborates the whole design — minutes and tens
  of gigabytes of heap, not seconds. It caches like anything else, so it happens
  when the pin moves or the configuration changes.
- CIRCT publishes no linux/arm64 `firtool`, so generation runs on a Mac or on the
  x86 cluster, but not on the arm64 one until somebody builds CIRCT from source.
- One file in YunSuan is patched, and has to be. It declares `class VIAluOpcode`
  and `object VialuOpcode` together, whose class files differ only in case, so on
  a case-insensitive filesystem one overwrites the other and a Bundle silently
  disappears. The patch moves one into its own file so the two can be compiled by
  two targets; see `ip/xiangshan/yunsuan_case_collision.patch`.

## Simulation

[Verilator](https://verilator.org) via
[rules_verilator](https://github.com/hw-bzl/rules_verilator), with the Verilator
toolchain itself coming from the Bazel Central Registry and built from source.
That is slow once and cached forever, and it means the simulator version is
pinned like everything else here rather than being whatever the machine had.

```
bazel test //hardware/...
```

A parameterised library cell is not a design and cannot be simulated directly —
it has no fixed width until something instantiates it. So each test provides a
small SystemVerilog top that fixes the parameters, and a C++ test that drives
it and checks the results against an independently computed expectation.

Where a design is combinational and narrow, the tests are exhaustive rather than
sampled: 256 vectors cost nothing and remove any argument about whether the
interesting case was covered.
