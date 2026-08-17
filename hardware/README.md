# Hardware

Designs, and the third-party IP they build on.

```
hardware/
  ip/           third-party IP, integrated but not vendored
    common_cells/
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
