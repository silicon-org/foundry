# Tailscale

The entire management and internal access plane. kubectl, talosctl, Grafana, and
remote-developer cache access all go over the tailnet. Nothing listens on a
public management port — invariant #4.

Chosen over Cloudflare Zero Trust because everything here is internal;
Cloudflare only earns its place if we later host something public-facing.

## Two halves, and only one of them can be a pod

**The Talos system extension** runs on every node and is configured in
[`../../talos/patches/`](../../talos/). It starts before Kubernetes, which is
the whole point: the Talos API on 50000 stays reachable over the tailnet when
the cluster is broken, which is exactly when it is needed.

The original plan was an in-cluster subnet router instead. That does not work,
for a reason worth keeping: it has to advertise the node network *when the
cluster's control plane does not*, and a pod cannot rescue the cluster it runs
in. Running it as an extension also removes the bastion VM the design would
otherwise have required.

**The operator** sits on top and does what the extension cannot: it publishes
in-cluster Services to the tailnet, and it runs the API server proxy.

## The extension is not free, and used to be very expensive

It is baked into the node image, and its service definition declares
`configuration: true`. Talos will not finish booting until an
`ExtensionServiceConfig` exists for it — so while it was unconfigured, every
node blocked in `startAllServices`, hit `BootTimeout` at 70 minutes, and
rebooted. Every node, every 71 minutes, for as long as that state lasted, which
killed any CI job that ran long and looked like a network fault.

An earlier version of this file described the extension as sitting "idle". That
was wrong, and it is why the cost stayed invisible: nothing points at the
extension until you correlate node boot times. There is no way to disable an
image-embedded extension service short of rebuilding the image.

## Credentials

OAuth clients, not auth keys. An auth key expires within 90 days and would sit
in the machine config dead, so a node reinstalled after that silently never
joins the tailnet — and an unreachable node is the case the tailnet exists for.
Client secrets do not expire, and tagged devices have key expiry disabled.

**One client per tag.** A client can only mint an auth key carrying *every* tag
it was created with; asking for a subset fails with `requested tags [...] are
invalid or not permitted`, which is also the message for a tag that does not
exist — so it sends you to the ACL, which is fine. Test a client without
creating anything:

```
curl -s https://api.tailscale.com/api/v2/oauth/token \
  -d client_id=$CID -d client_secret=$CSEC -d scope=auth_keys -d "tags=tag:foundry-cp"
```

The documented alternative — an owner tag both real tags inherit from — is worse
than it looks for the *nodes*. It would give the worker a credential able to
mint `tag:foundry-cp`, and that tag is what the route auto-approver trusts, so a
compromised worker could make itself subnet router for the private network.

For the **operator** the owner tag is exactly right, and its client therefore
carries `tag:k8s-operator` and nothing else. It needs to mint two different
things — a key for itself, and keys for the proxies it creates — and a
two-tag client cannot do that: it fails with
`creating operator authkey: requested tags [tag:k8s-operator] are invalid or
not permitted`, on startup, in a crash loop. `tag:k8s` is reached by ownership
instead (`"tag:k8s": ["tag:k8s-operator"]` in the policy file), which is what
the chart means by "Operator must be made owner of these tags". The difference
from the node case is that here the extra authority is the operator's own, and
the operator is already the thing creating proxies.

## Tags, and why the worker has its own

| Tag | Carried by | Advertises routes | Allowed as an ACL source |
|---|---|---|---|
| `tag:foundry-cp` | the three control planes | `10.0.0.0/16` | no |
| `tag:foundry-worker` | the CI worker | no | no |
| `tag:k8s-operator` | the operator | no | no |
| `tag:k8s` | proxies the operator creates | no | no |

No node is a source in any ACL rule, and none needs to be: cluster traffic rides
the private network by construction — `patches/hetzner.yaml` pins kubelet's node
IP and etcd's advertised address into `10.0.0.0/16` — and Tailscale's own
control and DERP traffic is not ACL-governed. The policy file carries tests
asserting this, and Tailscale refuses to save a policy whose tests fail, so it
is re-checked on every future edit rather than being a comment.

Only the control planes route. A subnet router forwards and can observe the
administrative traffic crossing it, and the worker executes pull request code.

## Access does not depend on subnet routes

The obvious design — advertise `10.0.0.0/16` and reach the API load balancer at
`10.0.1.5:6443` — needs `--accept-routes` on every client. That is per-device
state that lives in nobody's repository and gets forgotten exactly once, during
an incident.

So routes are the break-glass path, not the daily one:

| Need | Daily path | Needs routes? |
|---|---|---|
| `kubectl` | the operator's API server proxy | no |
| `talosctl` | nodes are tailnet devices; address them directly | no |
| Grafana, cache frontends | Services the operator publishes | no |
| Cluster broken, operator down | `talosctl`, still | no |
| The private load balancer itself | `--accept-routes`, deliberately | yes |

The proxy runs in auth mode: it impersonates the calling Tailscale identity, so
`kubectl` access is RBAC against a named user (see `rbac.yaml`) rather than
possession of a kubeconfig holding cluster CA credentials. Set it up with
`tailscale configure kubeconfig tailscale-operator`.

It is one operator pod, so the proxy is not highly available. A `ProxyGroup` of
type `kube-apiserver` is the fix if that ever matters; the alternative to a
brief outage is the break-glass rule rather than nothing.

## Not done yet

**No NetworkPolicy.** Every other component here has one and this does not,
which is a gap rather than a decision. Constraining it needs care: proxies need
egress to DERP relays worldwide on 443, STUN on UDP 3478, and direct WireGuard
to arbitrary peer addresses, so a policy written from first principles is
likelier to break relay fallback subtly than to contain anything.

**The policy file lives in a web console.** It is real infrastructure
configuration that is not in this repository, which cuts against how everything
else works. Tailscale can sync it from git via a GitHub Action; that needs its
own OAuth client and a workflow.

## The failure mode to plan for

If the tailnet is down, so is all administrative access. That is the accepted
cost of zero inbound ports, and it is why the break-glass Talos config
(`../../talos/`) is written before it is needed rather than during the outage.
Opening the firewall is `tofu apply -var="admin_access_enabled=true"`, and it
works during a tailnet outage because the Hetzner API is a separate control
plane.

Tailnet: `florianzaruba@gmail.com` (MagicDNS suffix `pogona-gila.ts.net`).
Deliberately a personal tailnet and not an employer's — this project's ACLs,
OAuth clients and device list must be ones we control. The practical cost is
that the macOS client is on one tailnet at a time, so reaching this cluster from
a machine signed in elsewhere means switching accounts.

The CLI is deliberately not pinned in `//tools` — see that README for why.
