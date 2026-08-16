# Platform

Everything Flux reconciles into the cluster. Git is the only interface: if it
isn't here, it isn't in the cluster, and nothing is applied by hand.

Flux was chosen over Argo CD deliberately — controllers rather than an app, no
extra UI or API server to secure, and a git-only interface that matches the
code-only discipline the rest of this repo enforces.

## Components

| Directory | What it is |
|---|---|
| `cilium/` | eBPF CNI: kube-proxy replacement, network policy, Hubble, L2 LoadBalancer. Also the enforcement point for runner isolation. |
| `cert-manager/` | TLS issuance. DNS-01 against `silicon-lang.org` at Cloudflare. |
| `kyverno/` | Admission control: block privileged pods and host namespaces, require rootless. |
| `secrets/` | SOPS+age encrypted secrets. Committed encrypted; never plaintext. |
| `tailscale/` | Tailscale Kubernetes operator and subnet router — the entire management plane. |
| `monitoring/` | kube-prometheus-stack, Loki, Hubble metrics, Buildbarn cache-hit metrics. |
| `buildbarn/` | Bazel remote execution + cache, with a read-only / read-write frontend split. |
| `arc/` | GitHub Actions runner scale set, ephemeral pods, plus its Cilium egress policy. |

## Ordering

Cilium comes first — without a CNI nothing else schedules. Flux bootstraps
against this repo immediately after. Everything below that is Flux
`Kustomization` dependencies, not manual sequencing.

## The rules that don't bend

The cross-cutting invariants from the
[architecture doc](../doc/architecture.md). Each has an owning directory, and
each is a testable claim rather than an intention:

1. Runners execute untrusted code — ephemeral pods, no standing secrets, no
   fork-PR execution. (`arc/`)
2. Runner isolation — default-deny on `arc-runners`, egress allow-list only,
   Pod Security Standards `restricted`, rootless builds. (`cilium/`, `arc/`,
   `kyverno/`)
3. Cache-poisoning prevention — untrusted builds cannot write the Action Cache,
   enforced at the network layer and not merely by configuration. (`buildbarn/`)
4. Zero inbound management ports. (`tailscale/`, `infra/tofu/`)
5. Secrets encrypted at rest, in git and in etcd. (`secrets/`, `infra/talos/`)
6. Break-glass documented and committed. (`infra/talos/`)
