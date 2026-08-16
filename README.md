# foundry

Hardware designs and the infrastructure that builds them, with Bazel as the
single build system across both. Part of the [Silicon](https://github.com/silicon-org)
project.

The premise: hardware development deserves the same build discipline software
development has had for a decade — hermetic, reproducible, incrementally cached,
distributed. One build graph from RTL through simulation and synthesis, with
remote execution and a shared cache doing the heavy lifting.

That requires infrastructure, so the infrastructure is built first, and it is
built the same way the designs will be: declaratively, in git, with nothing
configured by hand.

## Layout

| Path | Contents |
|---|---|
| [`tools/`](tools/README.md) | Pinned CLI toolchain. Every tool, one version, verified by hash. |
| [`infra/`](infra/README.md) | The build and CI cluster: OpenTofu, Talos, Flux, Buildbarn, ARC. |

Design trees land at the root alongside these once the infrastructure is boring.

## Getting started

Requires [bazelisk](https://github.com/bazelbuild/bazelisk) (which reads
`.bazelversion`) and, for the interactive tool PATH,
[direnv](https://direnv.net).

```
bazel run //tools:versions     # every pinned tool, at its pinned version
bazel run //tools:bazel_env    # then: direnv allow
```

Nothing else is installed. `kubectl`, `talosctl`, `tofu`, `helm` and `flux` all
come from Bazel at a fixed version — what runs on your laptop is what runs in
CI.

## Contributing

Pull requests from forks run on GitHub-hosted runners. They never run on this
project's self-hosted runners, and they can read the build cache but never write
it. That isn't distrust of you specifically — it's the only configuration in
which self-hosted CI on a public repository is safe. See
[`infra/platform/arc/`](infra/platform/arc/README.md) for the reasoning.

## Status

Early. The toolchain is pinned and the repository is scaffolded; the cluster
itself is being built. See [`infra/`](infra/README.md).
