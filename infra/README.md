# Infrastructure

The build and CI cluster this monorepo is built on: Bazel remote execution and
caching (Buildbarn) plus ephemeral GitHub Actions runners (ARC), on Kubernetes
on Talos Linux, provisioned with OpenTofu and reconciled by Flux.

Start with [`doc/architecture.md`](doc/architecture.md) — it carries the
rationale for every choice here, and the security invariants that constrain all
of them.

## Layout

| Path | Contents |
|---|---|
| `doc/` | Architecture and design notes. |
| `tofu/` | OpenTofu: Hetzner provisioning, private network, firewall. |
| `talos/` | talhelper: one base machine config plus per-environment overlays. |
| `platform/` | Everything Flux reconciles into the cluster. |

The pinned CLI toolchain (`tofu`, `talosctl`, `kubectl`, `helm`, `flux`, …) is
at [`//tools`](../tools/README.md), not here, because it also serves the
hardware side of the monorepo.

## Ground rules

- **Nothing is configured by hand on a node, ever.** Talos has no shell and no
  SSH; that is a property to lean on rather than work around.
- **Environments are overlays, not forks.** Local, cloud and dedicated differ by
  a small Talos config overlay over one base.
- **Git is the only interface to the cluster.** If it isn't committed here, it
  isn't running.
