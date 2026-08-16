# Tailscale

The entire management and internal access plane. kubectl, talosctl, Grafana, and
remote-developer cache access all go over the tailnet. Nothing listens on a
public management port — invariant #4.

Chosen over Cloudflare Zero Trust because everything here is internal;
Cloudflare only earns its place if we later host something public-facing.

## Operator and subnet router

Both, and they do different jobs:

- The **operator** exposes in-cluster Services to the tailnet cleanly, which is
  what Grafana and the Buildbarn frontends want.
- A **subnet router** advertises the node network, which is what raw `talosctl`
  to node IPs needs — and that has to work when the cluster's control plane does
  not, so it cannot depend on an in-cluster operator.

Tailnet: `florianzaruba@gmail.com` (MagicDNS suffix `pogona-gila.ts.net`).
Deliberately a personal tailnet and not an employer's — this project's ACLs,
OAuth clients and device list must be ones we control.

Needs a Tailscale OAuth client plus ACL tags (`tag:k8s-operator`, and a tag for
the runners so their egress is separable in ACLs). Stored SOPS-encrypted in
`../secrets/`.

## The failure mode to plan for

If the tailnet is down, so is all administrative access. That is the accepted
cost of zero inbound ports, and it is why the break-glass Talos config
(`../../talos/`) is written before it is needed rather than during the outage.

The CLI is deliberately not pinned in `//tools` — see that README for why.
