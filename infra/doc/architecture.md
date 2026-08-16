# Architecture

Why the build and CI cluster is built the way it is. Each choice carries its
rationale so it can be argued with rather than merely inherited.

## Goal

A self-hosted, scalable build and CI cluster with no vendor lock-in:

- Bazel remote execution and caching (Buildbarn)
- GitHub Actions self-hosted runners (ARC), ephemeral
- Kubernetes on Talos Linux, on Hetzner
- Everything infrastructure-as-code; nothing configured by hand on a node
- Management plane private via Tailscale; near-zero inbound ports

Every component is replaceable. That is the point of the constraint, not a
side effect of it: an EDA build farm that only works on one vendor's control
plane is a liability with a five-year half-life.

## Provisioning

**OpenTofu** with the Hetzner providers (`hcloud` for cloud servers, `robot` for
dedicated machines). Chosen over Terraform for the open-source license, which is
the same no-lock-in argument applied to the tool that owns our infrastructure
state.

**Talos Linux** as the node OS, configured with **talhelper**. Immutable and
API-driven, with no shell, no SSH and no package manager — which removes an
entire category of drift by removing the ability to drift. It is also the
portability layer: one base machine config with small overlays runs a local
Docker cluster, cloud VMs, and dedicated hardware.

**Bazel** as the hermetic entrypoint. It pins every CLI version and wraps
workflows as `bazel run` targets. It does not replace OpenTofu or Flux — see
non-goals.

## Cluster platform

Upstream Kubernetes, Talos-managed. Conformant and portable.

**Cilium** as CNI: eBPF dataplane, network policy, Hubble observability, L2
LoadBalancer, and a full kube-proxy replacement. It is also the enforcement
point for runner isolation, which is why the CNI choice is a security decision
and not just a performance one.

**Flux** for GitOps, chosen over Argo CD. Flux is a set of controllers rather
than an application, so there is no additional UI or API server to secure, and
its interface is git and nothing else — which matches the discipline the rest of
the repository enforces.

**cert-manager** for TLS, **SOPS + age** for secrets, **Kyverno** for admission
control, and etcd encryption-at-rest.

## CI and build

**ARC** (`gha-runner-scale-set`) with ephemeral runner pods, authenticated via a
GitHub App. Outbound-only to GitHub, so self-hosted CI needs zero inbound ports.

**Buildbarn** for remote execution and caching. Apache-2.0, and deployed with
separate read-only and read-write frontends — see the invariants below.

Rootless build tooling (rootless BuildKit, buildah). Never the host Docker
socket. **rules_oci** for container images, not the deprecated rules_docker.

## Access and monitoring

**Tailscale** carries the entire management and internal plane: kubectl,
talosctl, Grafana, and cache access for remote developers. Outbound-only, no
public management ports. Cloudflare Zero Trust is deliberately not used; it
would only earn its place if something here were public-facing.

**kube-prometheus-stack** (Prometheus, Grafana, Alertmanager) with **Loki** for
logs, Cilium/Hubble for network flow metrics, and Buildbarn metrics for cache
hit rate and remote-execution performance.

Exactly one uptime check lives off-cluster. Self-hosted monitoring cannot page
you when the box it runs on is the thing that died.

## Non-goals

- **Do not model OpenTofu state or generate Kubernetes YAML in Starlark.**
  OpenTofu owns provisioning state; Flux and Helm own manifests; Bazel owns tool
  versions and hermetic entrypoints. Collapsing those boundaries produces a build
  system that cannot be reasoned about and infrastructure that cannot be
  recovered.
- **Do not expose the Kubernetes API (6443), the Talos API (50000), or any
  dashboard to the public internet.** Tailscale only.
- **Do not mount the host Docker socket into runners.** It is root on the node,
  spelled differently.
- **Do not run untrusted fork pull requests on self-hosted runners.**
- **Do not configure anything by SSH-ing into a node.** Talos has no shell. That
  is a feature to lean on, not an obstacle to route around.

## Security invariants

These are the doors that actually get self-hosted CI compromised. They are
acceptance criteria, not aspirations, and each is a testable claim.

1. **Runners execute untrusted code.** Ephemeral pods, no standing secrets in
   the runner environment, the scale set gated to trusted repositories and
   workflows, and no fork-PR execution.
2. **Runner isolation.** Cilium default-deny on the `arc-runners` namespace with
   an egress allow-list only: DNS, GitHub, the read-only Buildbarn frontend, and
   the dependency registries builds actually need. Pod Security Standards
   `restricted`. Rootless builds.
3. **Cache-poisoning prevention.** Untrusted builds cannot write the Action
   Cache. Enforced by separate read-only and read-write frontends divided at the
   network layer, not by configuration alone — a flag is one typo away from being
   wrong, and a route is not.
4. **Zero inbound management ports.** All administrative access over Tailscale.
5. **Secrets encrypted.** SOPS + age in git; etcd encryption-at-rest enabled.
6. **Break-glass documented.** A declarative Talos configuration permitting API
   access from a single administrative IP, committed but normally inactive, for
   use during a tailnet outage. Written before it is needed, because the moment
   it is needed is the worst moment to be writing it.

## Repository layout

```
tools/            pinned CLI toolchain, shared by infrastructure and designs
infra/
  doc/            this document
  tofu/           Hetzner provisioning, private network, firewall
  talos/          talhelper: base machine config plus environment overlays
  platform/       everything Flux reconciles into the cluster
    cilium/  cert-manager/  kyverno/  secrets/
    tailscale/  monitoring/  buildbarn/  arc/
```

Environments differ by a small Talos configuration overlay over one base, never
by a fork.

## Hardware

Nodes and remote-execution workers are arm64: developer machines are Apple
Silicon and cluster nodes are Hetzner CAX. Remote execution requires worker
platforms to match what actions need, so this constrains the toolchain —
anything that must run under remote execution has to build and run on arm64.
Revisit only if a required tool ships x86-Linux-only.
