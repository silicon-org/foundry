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

**SOPS + age** for secrets and etcd encryption-at-rest. **cert-manager** for
TLS, once something needs a certificate. **Kyverno** is not deployed: the
policies it was intended for are already enforced by the Pod Security Standards
`restricted` label, and an admission controller that repeats an existing check
is motion rather than defence in depth.

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
public management ports. It runs as a Talos *system extension* on each node
rather than as an in-cluster subnet router, because it has to work when the
cluster does not — a pod cannot rescue the cluster it runs in. Not yet
configured: the extension is present in the image and idle, and access is
currently the break-glass firewall rule instead. Cloudflare Zero Trust is deliberately not used; it
would only earn its place if something here were public-facing.

**kube-prometheus-stack** (Prometheus, Grafana, Alertmanager) with **Loki** for
logs, on the Hetzner cluster only — both want a PersistentVolume, and metric
history on a cluster that `bazel run //infra/talos:down` deletes is history of
nothing.

Scraped: the Kubernetes control plane, every node, all six Buildbarn components,
the ARC controller and listener, Cilium and Hubble, the Flux controllers and the
Buildbarn portal. Logs from every pod on every node, shipped by Grafana Alloy,
kept seven days. Dashboards and alert rules are committed as files; Grafana is
stateless on purpose, so a dashboard edited in the browser is gone at the next
restart and one edited in git is not.

Two things are deliberately not done yet, and both are recorded rather than
forgotten. **Alerts fire but go nowhere** — the rules are evaluated and
validated at commit time by `//infra/platform:promtool_test`, and the
Alertmanager route points at a null receiver until a destination is chosen.
And **there is still no check outside this cluster**: self-hosted monitoring
cannot page you when the box it runs on is the thing that died. The intended
shape is a dead man's switch rather than a reachability probe — Alertmanager's
always-firing Watchdog pings an external service, which alerts when the pings
stop. That covers the cluster being down, but also Prometheus being down, and
the whole stack having been quietly broken by a bad values change. It also needs
nothing public-facing, which a reachability probe would.

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
3. **Cache-poisoning prevention.** Two frontends exist and the read-only one
   refuses Action Cache writes. **The network half of this is not in place**: the
   runner policy currently allows both, because a namespace-level rule cannot
   tell a push from a pull request, so no build is presently restricted to the
   read-only endpoint. This is the one invariant on this list that is an
   intention rather than a fact, and it is recorded that way deliberately — the
   reasoning and the conditions that should end it are in
   `platform/arc/networkpolicy.yaml`.
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
    cilium/  hcloud/  buildbarn/  arc/  monitoring/  secrets/
    cert-manager/  kyverno/  tailscale/                 (not yet deployed)
    clusters/     which components each cluster runs
```

`clusters/` is how one set of components serves more than one cluster:
`clusters/local/` and `clusters/hetzner/` each select the components they want
and patch the handful of values that genuinely differ. A second cluster is a
sibling directory, never a branch and never a fork of the components.

Environments differ by a small Talos configuration overlay over one base, and by
a small kustomize overlay over one set of manifests. Both are overlays for the
same reason: a fork drifts and nobody notices until the two behave differently.

## Hardware

Two clusters, two architectures. The local one is Talos in Docker on an Apple
Silicon Mac, so arm64. The cloud one is Hetzner x86.

That split is not a preference. The original intent was arm64 everywhere —
developer machines are Apple Silicon and Hetzner's CAX line is arm64 and cheap,
so one architecture would have covered everything. When the cloud cluster was
built, every CAX type was out of stock in every Hetzner location, and the
alternatives with arm64 in stock cost three to six times as much for the same
specification. So the cloud cluster is x86, and the constraint is gone.

What makes that affordable rather than disruptive is that the C++ toolchain is
a Bazel dependency rather than something installed on a machine. hermetic-llvm
cross-compiles from one Mac to both targets, so supporting a second
architecture is two lines in `MODULE.bazel` and a second `platform` — not a
second build environment. Had the toolchain been baked into worker images, this
would have been a rebuild of everything instead.

The cost is real but bounded: an action's cache entry is per-platform, so the
two clusters do not share results. They already did not — macOS and Linux
differ regardless — and each cluster's cache is internally consistent, which is
what actually matters.

Both `//platforms:linux_arm64` and `//platforms:linux_amd64` are therefore
maintained, and `exec_properties` on each must match what the corresponding
Buildbarn worker advertises. Anything that must run under remote execution has
to build and run on whichever architecture its cluster has.
