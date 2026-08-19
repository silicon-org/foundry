# Talos machine configuration

Talos Linux is the node OS: immutable, API-driven, no shell, no SSH, no package
manager. It is also the portability layer — the same base config runs locally,
on cloud VMs, and on dedicated hardware, differing only by a small overlay.

## The local cluster

```
bazel run //infra/talos:up          # Talos in Docker, 1 control plane + 1 worker
bazel run //infra/talos:kubeconfig  # merge credentials into ~/.kube/config
bazel run //infra/talos:down
```

Requires a running Docker daemon. The cluster has no CNI until Cilium is
reconciled into it, so nodes stay `NotReady` until then — expected, not a
failure.

## Configuration layout

| File | Role |
|---|---|
| `patches/base.yaml` | Settings identical in every environment. |
| `patches/local.yaml` | Docker-specific overrides. |
| `patches/hetzner.yaml` | Hetzner overrides, all machines. |
| `patches/hetzner-controlplane.yaml` | Hetzner overrides Talos rejects on a worker. |

Talos' Docker provisioner generates machine configs itself, so
[talhelper](https://github.com/budimanjojo/talhelper) — which generates configs
but does not provision — has no role locally. Cloud and dedicated machines use
talhelper, and it consumes **the same patch files**.

That is what makes environments overlays rather than forks. The shared thing is
the patch, not a generator: the settings that matter are identical everywhere by
construction, and the per-environment file stays small enough to read in one
sitting. When `local.yaml` starts growing, that is the signal something has been
special-cased that should not have been.

talhelper's rendered output (`clusterconfig/`) and any plaintext
`talsecret.yaml` are gitignored. Only the encrypted secret is ever committed.

## Verified rather than assumed

**etcd encryption at rest.** Talos generates a
`cluster.secretboxEncryptionSecret` by default and wires the API server to it,
so Kubernetes secrets are encrypted in etcd without us configuring anything.
Precisely because it is a default rather than something we set, confirm it on
the running cluster rather than trusting it:

```
kubectl -n kube-system get pod -l k8s-app=kube-apiserver \
  -o jsonpath='{.items[0].spec.containers[0].command}' | tr ',' '\n' | grep encryption-provider-config
```

Note that this is also why `patches/base.yaml` does *not* set
`encryption-provider-config` itself: Talos already manages that flag and its
config file path, and overriding it points the API server at a file that does
not exist.

## What the control plane exposes, and to whom

Three settings here exist only so that monitoring has something to scrape, and
they are worth knowing about because they open ports rather than close them.

- `cluster.controllerManager.extraArgs.bind-address` and the same for
  `scheduler`, in `patches/hetzner-controlplane.yaml`. Both bind to `127.0.0.1`
  by default, which means their metrics endpoint exists and is reachable by
  nothing — so the scrape jobs kube-prometheus-stack ships for them are targets
  that are permanently down. A target expected to be down is worse than no
  target: people learn to scroll past it.
- `cluster.etcd.extraArgs.listen-metrics-urls`, in
  `patches/hetzner-controlplane.yaml`. This is etcd's *dedicated* metrics
  listener, serving `/metrics` and `/health` and nothing else, which is what
  makes an unauthenticated listener acceptable. The alternative is mounting etcd
  client certificates into Prometheus — handing a scrape job the credentials to
  read every secret in the cluster in order to draw a graph.

What keeps 10257, 10259 and 2381 off the internet is the Hetzner firewall in
`infra/tofu`, which is an allow-list. Verify that against the applied firewall
rather than against this paragraph — "should already be closed" is the phrasing
that precedes an exposure. The kubelet's 10250 is the easy control: it listens
on every interface, so if it is unreachable from outside, so are these.

```
nc -z -w5 <control-plane-public-ip> 10250   # expect: refused/filtered
```

One thing Prometheus cannot discover for itself: Talos runs etcd as a Talos
service rather than a static pod, so there is no Pod object in `kube-system` to
select and the chart's Service would have no endpoints whatever the machine
config said. The three control-plane addresses are therefore named explicitly in
`infra/platform/monitoring/values-kube-prometheus-stack.yaml`. That is the one
place a change to `control_plane_count` has to be mirrored by hand.

Talos itself exports no Prometheus endpoint, and that is not an oversight to fix
later. Node-level signal comes from node-exporter; Talos-level signal comes from
`talosctl`.

Applying any of this is `bazel run //infra/talos:genconfig` followed by a
rolling `talosctl apply-config`, one node at a time. It touches the control
plane, so it is the one monitoring change where a mistake costs more than a
dashboard.

## Also owned here

- **Break-glass**: a config patch permitting Talos API access from a single
  administrative IP, committed but normally inactive, for use during a tailnet
  outage. Written before it is needed, because the moment it is needed is the
  worst moment to be writing it.
- **The Talos API (50000) is never exposed publicly.** Reachable over the
  tailnet only.

## On the local environment

The local overlay exercises Flux reconciliation, Buildbarn and ARC perfectly
well. It does *not* exercise Cilium's kube-proxy replacement, L2
LoadBalancer/LB-IPAM, or the Tailscale path: Docker Desktop's bridge network is
not routable from the host, so those behave differently or not at all. kube-proxy
is therefore left enabled locally and disabled in cloud environments.

Conclusions about the network dataplane have to come from real VMs, and a
single-node etcd says nothing about HA.
