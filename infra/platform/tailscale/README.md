# Tailscale

The entire management and internal access plane. kubectl, talosctl, Grafana, and
remote-developer cache access all go over the tailnet. Nothing listens on a
public management port — invariant #4.

Chosen over Cloudflare Zero Trust because everything here is internal;
Cloudflare only earns its place if we later host something public-facing.

## Not configured yet

The Talos system extension is already in the node image and sits idle, reporting
`Waiting for extension service config`. Until it is given an auth key, access to
the Hetzner cluster is the break-glass firewall rule instead — one
administrative address allowed to 6443 and 50000. That is a deliberate
temporary posture, not the design, and it is the reason invariant #4 is
currently relaxed.

## A node extension, not a subnet router

The original plan was an in-cluster operator plus a subnet router pod. The
subnet router half does not work, for a reason worth keeping: it has to advertise
the node network *when the cluster's control plane does not*, and a pod cannot
rescue the cluster it runs in.

So Tailscale runs as a Talos **system extension** on each node. It starts before
Kubernetes, which means the Talos API on 50000 stays reachable over the tailnet
even when nothing else is — exactly when it is needed. It also removes the
bastion VM the design would otherwise have required.

The **operator** still earns its place on top, for exposing in-cluster Services
cleanly: Grafana, and the Buildbarn frontends for remote developers.

Nodes advertise the private network as a tailnet route, which is what makes the
private load balancer holding the Kubernetes API reachable at all. Routes need
approving once in the admin console, or automatically via an ACL autoApprover.

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
