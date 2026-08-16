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

## How it fits together

| File | Role |
|---|---|
| `multitool.lock.json` | URLs + SHA-256 per tool per platform. The actual pin. |
| `tools.bzl` | `TOOLS`: the tool list, and how each reports its version. |
| `BUILD.bazel` | Derives `:bazel_env` and `:versions` from `TOOLS`. |
| `versions.sh` | Runs each tool and reports the version it claims. |

`TOOLS` is the single source of truth: adding a tool means adding binaries to
the lockfile and one line to `tools.bzl`. The PATH environment and the version
report cannot drift apart, because both are generated from that one dict.

## Platforms

The lockfile carries `macos`/`linux` × `arm64`/`x86_64`. We *deploy* arm64 only
(dev machines are Apple Silicon, cluster nodes are Hetzner CAX), but the lockfile
is machine-maintained and pruning it would mean fighting the updater on every
bump — for a saving of a few dozen lines of JSON.

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

## What is deliberately not pinned here

**`tailscale`.** Tailscale publishes no CLI binaries on GitHub releases; Linux
comes from `pkgs.tailscale.com` and macOS ships as a signed `.pkg`/App Store
app with no standalone CLI tarball. There is no clean hermetic pin, so the
dev-machine CLI stays a host prerequisite. The part that matters for the cluster
is the Tailscale Kubernetes operator, which Flux manages as a Helm release — see
`infra/platform/tailscale/`.

**`bazel` itself.** `.bazelversion` plus bazelisk already handles that.
