# Platform

Everything Flux reconciles into the cluster. Git is the only interface: if it
isn't here, it isn't in the cluster, and nothing is applied by hand.

Flux was chosen over Argo CD deliberately — controllers rather than an app, no
extra UI or API server to secure, and a git-only interface that matches the
code-only discipline the rest of this repo enforces.

## Components

Deployed:

| Directory | What it is |
|---|---|
| `cilium/` | eBPF CNI: network policy, Hubble, and kube-proxy replacement where the node networking supports it. Also the enforcement point for runner isolation. |
| `hcloud/` | Hetzner cloud controller manager and CSI driver. Cloud clusters only; nothing schedules until the CCM clears the uninitialized taint. |
| `buildbarn/` | Bazel remote execution + cache. Two frontends, read-only and read-write — see its README for what that does and does not currently enforce. |
| `arc/` | GitHub Actions runner scale set, ephemeral pods, plus its Cilium egress policy. |
| `secrets/` | Not a component: how SOPS+age works here, and the one secret created by hand. |
| `clusters/` | Which components each cluster runs, and the few values that differ. |

Not deployed, and each README says why:

| Directory | Status |
|---|---|
| `cert-manager/` | Nothing needs a certificate yet. |
| `kyverno/` | Pod Security Standards already enforce what it was for. |
| `tailscale/` | The Talos system extension is in the node image and idle; access is currently the break-glass firewall rule. |
| `monitoring/` | Still a stub. A cache with no alerting fails silently, which makes this the next real gap. |

## Ordering

Two things are installed by hand, once per cluster, because GitOps cannot
bootstrap what GitOps depends on:

1. **Cilium**, because Flux's controllers cannot be scheduled onto a cluster
   with no CNI.
2. **The cloud controller manager**, on cloud clusters, because the kubelet
   taints every node `uninitialized` until one clears it and Flux does not
   tolerate that taint. Cilium escapes the same trap only because a DaemonSet
   tolerates everything, which is why this one is easy to miss.

Flux bootstraps after those, and everything below is `Kustomization`
`dependsOn`, not manual sequencing.

## The rules that don't bend

The cross-cutting invariants from the
[architecture doc](../doc/architecture.md). Each has an owning directory, and
each is a testable claim rather than an intention:

1. Runners execute untrusted code — ephemeral pods, no standing secrets, no
   fork-PR execution. (`arc/`)
2. Runner isolation — default-deny on `arc-runners`, egress allow-list only,
   Pod Security Standards `restricted`, rootless builds. (`cilium/`, `arc/`)
3. Cache-poisoning prevention — the read-only frontend refuses Action Cache
   writes, but the network half is **not** in place: the runner policy allows
   both frontends today. The only aspiration on this list, marked as one.
   (`buildbarn/`, `arc/`)
4. Zero inbound management ports. Currently relaxed to one administrative
   address while Tailscale is unconfigured. (`tailscale/`, `infra/tofu/`)
5. Secrets encrypted at rest, in git and in etcd. (`secrets/`, `infra/talos/`)
6. Break-glass documented and committed. (`infra/talos/`)
