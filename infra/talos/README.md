# Talos machine configuration

Talos Linux is the node OS: immutable, API-driven, no shell, no SSH, no package
manager. It is also the portability layer — the same base config runs locally,
on Hetzner Cloud VMs, and later on dedicated hardware, differing only by a small
overlay.

Managed with [talhelper](https://github.com/budimanjojo/talhelper), pinned at
`//tools`.

## Planned contents

| File | Role |
|---|---|
| `talconfig.yaml` | Base cluster + node definitions. |
| `talenv.yaml` | Talos / Kubernetes versions, per environment. |
| `talsecret.sops.yaml` | Cluster PKI and secrets, SOPS-encrypted. |
| `patches/` | Overlays: local (docker), vm (hcloud), dedicated. |

`clusterconfig/` (talhelper's rendered output) and any plaintext `talsecret.yaml`
are gitignored. Only the encrypted secret is committed.

## Invariants this directory is responsible for

- **etcd encryption-at-rest is on.** Set in the base config, not per environment.
- **Break-glass is declarative and committed but normally inactive.** A config
  patch permitting Talos API access from a single admin IP, applied only during
  a tailnet outage. Writing it down beforehand is the difference between a bad
  afternoon and a rebuild.
- **The Talos API (50000) is never exposed publicly.** Reachable over the
  tailnet only.

## On the local environment

The local overlay runs Talos in Docker (`talosctl cluster create`), which
exercises Flux reconciliation, Buildbarn and ARC perfectly well. It does *not*
exercise Cilium's kube-proxy replacement, L2 LoadBalancer/LB-IPAM, or the
Tailscale path: Docker Desktop's bridge network is not routable from the host,
so those behave differently or not at all. Conclusions about the network
dataplane have to come from real VMs.
