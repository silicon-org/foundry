# OpenTofu

Provisioning: Hetzner Cloud servers, private network, firewall. Later, Hetzner
Robot for dedicated machines.

```
bazel run //infra/tofu:init
bazel run //infra/tofu:plan
bazel run //infra/tofu:apply
bazel run //infra/tofu:fmt -- -check
```

Empty for now by design — the wrappers exist so the pattern is proven before it
has to be trusted with real resources.

## Why wrappers instead of just running `tofu`

Bazel *invokes* tofu at a pinned version. Bazel does not model tofu state, and
no `.tf` is generated from Starlark. That boundary is a non-goal in the spec
(§3) and it is what keeps this portable: tofu owns provisioning state, Flux and
Helm own manifests, Bazel owns only tool versions and hermetic entry points.

Consequently the wrappers `cd` into `$BUILD_WORKSPACE_DIRECTORY/infra/tofu`
before exec'ing tofu, so state and provider locks land in the source tree rather
than in a sandbox that gets discarded. See `tofu.bzl`.

## What lands here

- `hcloud` provider and CAX (arm64) servers — three control-plane nodes, so etcd
  quorum is real rather than nominal.
- A private network, and a firewall denying all inbound. Access is outbound-only
  via Tailscale; in particular `6443` (Kubernetes API) and `50000` (Talos API)
  must never be reachable from the public internet.
- A remote state backend. Local state is tolerable for a single operator and
  stops being tolerable the moment it isn't one.
