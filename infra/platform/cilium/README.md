# Cilium

eBPF CNI, installed before anything else — without it nothing schedules.
Replaces kube-proxy entirely.

Three jobs, in increasing order of how much they matter:

- **CNI.** Pods can talk. The baseline.
- **L2 announcements / LB-IPAM** for in-cluster service addresses, and Hubble
  for flow visibility. Neither behaves like production under Talos-in-Docker,
  where the bridge network is not routable from the host.
- **Runner isolation**, which is the one that matters. A default-deny
  `CiliumNetworkPolicy` on the `arc-runners` namespace with an egress allow-list:
  DNS, GitHub, the read-only Buildbarn frontend, and whichever dependency
  registries the builds genuinely need. The test is behavioural, not
  configurational: a runner pod must be unable to reach `6443`, `50000`, other
  namespaces, or the open internet.

Installed as a Helm release via Flux, not with the `cilium` CLI. The CLI is
pinned at `//tools` for `cilium status` and `cilium connectivity test`.
