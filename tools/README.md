# Pinned CLI toolchain

Every CLI this monorepo depends on is fetched by Bazel at a pinned version and
verified by SHA-256. Nothing resolves from `$PATH` on your laptop, and nothing
is installed by hand.

This lives at the repo root rather than under `infra/` because it serves the
whole monorepo: today it pins the cluster tools, and the hardware toolchain
(simulators, synthesis, formal) plugs into the same mechanism.

## Using the tools

Through Bazel, one at a time:

```
bazel run @multitool//tools/kubectl -- get nodes
```

Or interactively, which is what you actually want for cluster work:

```
bazel run //tools:bazel_env
direnv allow
kubectl get nodes          # the pinned v1.36.3, not whatever's on your system
```

`bazel_env` symlinks the pinned tools into `bazel-out/.../bazel_env/bin`, and
`.envrc` puts that directory on `PATH` via [direnv](https://direnv.net). Install
direnv and enable its shell hook once per machine.

To see everything that is pinned:

```
bazel run //tools:versions
```

To scan for committed secrets — this repository is public, so a secret committed
here is a secret published:

```
bazel run //tools:secret-scan -- git --redact
```

## Formatting

One command formats the whole tree, and one test fails when it disagrees with
what is committed:

```
bazel run //tools/format               # rewrite every file
bazel run //tools/format -- a.cc b.h   # rewrite these
bazel test //tools/format:format_test  # what CI asks
```

`format` is on `PATH` alongside the pinned CLIs, which is how `tools/githooks/pre-commit`
runs it on the staged files without paying Bazel's startup. `direnv allow`
installs that hook by pointing `core.hooksPath` at `tools/githooks`; `git commit
--no-verify` skips it, and the test does not.

Neither formatter is fetched for the purpose. clang-format is the one inside the
hermetic C++ toolchain, so it moves when the compiler does; buildifier is a pin
in `multitool.lock.json` like everything else in this file. See
`//tools/format:defs.bzl`.

## How it fits together

| File | Role |
|---|---|
| `multitool.lock.json` | URLs + SHA-256 per tool per platform. The actual pin. |
| `tools.bzl` | `TOOLS`: the tool list, and how each reports its version. |
| `BUILD.bazel` | Derives `:bazel_env` and `:versions` from `TOOLS`. |
| `versions.sh` | Runs each tool and reports the version it claims. |
| `format/` | Which formatter owns which language, and the test that enforces it. |

`TOOLS` is the single source of truth: adding a tool means adding binaries to
the lockfile and one line to `tools.bzl`. The PATH environment and the version
report cannot drift apart, because both are generated from that one dict.

## Platforms

The lockfile carries `macos`/`linux` × `arm64`/`x86_64`, and all four now earn
their place: developer machines are Apple Silicon, the local cluster is arm64,
and the Hetzner cluster is x86 — because Hetzner's arm64 line was out of stock
everywhere when it was built.

That is worth noting as a small vindication of not pruning. Keeping every
platform was originally justified only by the lockfile being machine-maintained,
where trimming it would mean fighting the updater on every bump for a saving of
a few dozen lines of JSON. Then the cluster changed architecture and every
entry was needed after all.

## Updating versions

Most tools come from GitHub releases and update automatically:

```
bazel run //tools:update -- --lockfile tools/multitool.lock.json update
```

Two do not ship on GitHub releases and must be bumped by hand in
`multitool.lock.json`:

- **kubectl** — `https://dl.k8s.io/release/vX.Y.Z/bin/<os>/<arch>/kubectl`,
  with checksums at the same URL plus `.sha256`.
- **helm** — `https://get.helm.sh/helm-vX.Y.Z-<os>-<arch>.tar.gz`, checksums at
  the same URL plus `.sha256sum`. Note the binary sits at `<os>-<arch>/helm`
  inside the archive.

After any bump, `bazel run //tools:versions` is the check that it worked.

## Build tools, which are a different thing

`espresso/` and `firtool/` are not part of the mechanism above. They are not CLIs
anybody types; they are compilers that build actions invoke, so they belong in the
build graph rather than on `PATH`, and they are fetched by `http_archive` in
`//MODULE.bazel` with the BUILD file that describes them living here.

| Tool | Where it comes from | Why |
|---|---|---|
| `espresso` | built from source, pinned commit | Logic minimiser Chisel folds decoder tables with. Thirty C files, so building it costs nothing and works on every platform the toolchain targets. |
| `firtool` | CIRCT release binary, pinned version | Compiles the FIRRTL a Chisel generator emits into SystemVerilog. Pinned to the version Chisel records in `etc/circt.json`, because that is the pairing upstream tests. |

They live under `//tools` and not beside the IP that needs them for the same
reason the C compiler does not live beside a C file: nothing they produce ends up
in a design.

`firtool` has no linux/arm64 build, so Chisel elaboration runs locally on a Mac or
remotely on the x86 cluster, but not on the arm64 one. `espresso` is built from
source precisely so it does not add a second such constraint.

## Waveform debugging

**`tsunami-serve`** is pinned like every other CLI here. It is the query engine
behind the MCP server in `//.mcp.json`, so `bazel run //tools:bazel_env` is what
puts a working waveform tool on `PATH`:

```
bazel run //hardware/soc/xs_cluster/tb:xs_cluster_tb_traced -- +dump +dumpfile=/tmp/xs.fst
```

then ask the `tsunami` MCP server to open `/tmp/xs.fst`.

Upstream published no binaries until
[zarubaf/tsunami#3](https://github.com/zarubaf/tsunami/pull/3); the Linux builds
are static musl, so the pin has no glibc floor and runs on the Talos workers.

## What is deliberately not pinned here

**`tailscale`.** Tailscale publishes no CLI binaries on GitHub releases; Linux
comes from `pkgs.tailscale.com` and macOS ships as a signed `.pkg`/App Store
app with no standalone CLI tarball. There is no clean hermetic pin, so the
dev-machine CLI stays a host prerequisite. The part that matters for the cluster
is the Tailscale Kubernetes operator, which Flux manages as a Helm release — see
`infra/platform/tailscale/`.

**`bazel` itself.** `.bazelversion` plus bazelisk already handles that.
