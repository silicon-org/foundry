# Configure Tailscale

Plan of record. Three things at once, because they are the same secret and the
same admin-console visit:

1. **The node extension**, which stops the cluster rebooting itself every 71
   minutes. `siderolabs/tailscale` is in the image with `configuration: true`
   in its service definition, so Talos blocks `startAllServices` waiting for an
   `ExtensionServiceConfig` that does not exist, hits `BootTimeout` (70m), and
   machined reboots the node. This is the fix, not a mitigation.
2. **The operator's API server proxy**, which is how `kubectl` reaches the
   cluster without any per-device setup.
3. **The operator's Service exposure**, which retires `tunnel.sh`.

M1 is the urgent half and depends on nothing below it.

## Verified before writing this

- Extension is tailscale **1.98.9** (`talosctl get extensions`), so the
  `TS_CLIENT_ID` / `TS_CLIENT_SECRET` OAuth path exists -- checked in
  `cmd/containerboot/{settings,tailscaled}.go` at that tag. `--advertise-tags`
  must accompany it.
- `tailscaleUp` emits `--accept-dns=false` unless asked otherwise, so MagicDNS
  will not rewrite a node's resolv.conf and cannot disturb cluster DNS.
- talhelper 3.1.16 passes a **multi-document** patch through to the generated
  config: an `ExtensionServiceConfig` document in `patches/` lands in the node
  configs. Tested against a scratch copy of `infra/talos/`.
- `talenv.sops.yaml` is auto-loaded by `genconfig` and `${VAR}` substitution
  into the patch works. Tested the same way.
- Sharing a node into another tailnet does **not** carry its subnet routes
  ("Shared machines do not advertise subnets to the tailnets they're shared
  into"), so a share cannot substitute for tailnet membership here.

## Access design: why subnet routes are not the primary path

The obvious design -- advertise `10.0.0.0/16`, reach the private API load
balancer at `10.0.1.5:6443` -- works, but it needs `--accept-routes` on every
client. That is per-device state that lives in nobody's repository and is
forgotten exactly once, by the next person, during an incident.

So routes are the **break-glass** path, not the daily one:

| Need | Daily path | Needs routes? |
|---|---|---|
| `kubectl` | operator API server proxy, a tailnet FQDN with a real cert | no |
| `talosctl` | the nodes are tailnet devices; address them directly | no |
| Grafana, cache frontends | operator-exposed Services | no |
| Cluster broken, operator down | `talosctl` direct, still no routes | no |
| Private LB / anything unexposed | `--accept-routes`, deliberately | yes |

Nodes still advertise the route, since advertising costs nothing and the
break-glass case is real. Nothing depends on a client having accepted it.

A second benefit worth stating: the API server proxy authenticates by Tailscale
identity and impersonates it, so a laptop no longer needs a long-lived
cluster-admin kubeconfig sitting in `infra/talos/clusterconfig/`.

## Two tags, because one node runs untrusted code

A subnet router forwards and can observe the admin traffic crossing it. The
worker runs untrusted CI by design, so it must not be that router. Control
planes run no workloads (`allowSchedulingOnControlPlanes: false`) and are the
right place for it.

Neither tag gets any ACL rights as a *source*. The nodes need none: cluster
traffic rides the private network by construction (`patches/hetzner.yaml` pins
kubelet's node IP and etcd's advertised address into `10.0.0.0/16`), and
Tailscale's own control and DERP traffic is not ACL-governed.

## M0 - Tailscale admin console and laptop (needs a human)

The tailnet is the personal one, `florianzaruba@gmail.com` /
`pogona-gila.ts.net`. This laptop is normally signed in to a separate work
tailnet whose ACLs are not ours to edit, so confirm the switcher reads
`pogona-gila.ts.net` before saving anything.

- [ ] Access Controls: paste the policy file -- `groups`, `tagOwners`
      (`tag:foundry-cp`, `tag:foundry-worker`, `tag:k8s-operator`, `tag:k8s`),
      `autoApprovers` for `10.0.0.0/16` by `tag:foundry-cp`, the three `acls`
      rules, and the `tests` block
- [ ] OAuth client **foundry-cp**: scope `auth_keys` write, tag
      `tag:foundry-cp` **only**
- [ ] OAuth client **foundry-worker**: scope `auth_keys` write, tag
      `tag:foundry-worker` **only**

      One client per tag, because a client mints keys carrying *every* tag it
      was created with and a subset request is refused. Verified against the
      API. Sharing one client via an owner tag would let the untrusted worker
      mint a `tag:foundry-cp` key, and that tag is what the route auto-approver
      trusts -- so the worker could make itself subnet router. Create these
      after the ACL: the tag picker reads `tagOwners`.
- [ ] OAuth client **foundry-operator**: scopes `auth_keys` write +
      `devices:core` write, tag `tag:k8s-operator` **only**. Not `tag:k8s` as
      well -- same all-or-nothing rule, and the operator needs to mint a key
      for itself separately from the proxies'. It reaches `tag:k8s` by
      ownership, which the ACL already grants.
- [ ] Laptop: add the personal account alongside the work one (switching, not
      replacing)

Two OAuth clients rather than one, so the node credential and the in-cluster
credential revoke independently. The in-cluster one is the one that leaks.

The `tests` block is the point of the ACL, not decoration: Tailscale refuses to
save a policy file whose tests fail, so "the worker cannot open a connection to
my laptop" is re-checked on every future edit.

## M1 - Node extension (stops the reboot loop)

- [ ] `.sops.yaml`: rule for `talenv\.sops\.ya?ml$` encrypting **everything**.
      Without it the default rule's `encrypted_regex: ^(data|stringData)$`
      matches nothing and sops writes the credentials out in the clear, exit 0,
      no warning -- the exact trap `infra/platform/secrets/README.md` documents
      and `talsecret.sops.yaml` already has a rule for.
- [ ] `infra/talos/talenv.sops.yaml`: `TS_CP_CLIENT_ID`/`TS_CP_CLIENT_SECRET`
      and `TS_WORKER_CLIENT_ID`/`TS_WORKER_CLIENT_SECRET`
- [ ] `infra/talos/patches/tailscale-controlplane.yaml`: tag `tag:foundry-cp`,
      `TS_ROUTES=10.0.0.0/16`
- [ ] `infra/talos/patches/tailscale-worker.yaml`: tag `tag:foundry-worker`,
      no routes
- [ ] `talconfig.yaml`: wire them via `controlPlane.patches` and
      `worker.patches`, the same split `hetzner-controlplane.yaml` already uses
- [ ] `bazel run //infra/talos:genconfig`
- [ ] `talosctl apply-config` to all four nodes -- **no reboot flag**. The
      config lands, the resource appears, `ext-tailscale` starts, and the
      pending boot sequence finishes. Rebooting would only restart the timer.

Verify:

- [ ] `talosctl get extensionserviceconfigs` shows `tailscale`
- [ ] `talosctl services ext-tailscale` is `Running`, not `Waiting`
- [ ] four devices in the tailnet, correctly tagged, route advertised by the
      three control planes only
- [ ] `talosctl` works against a node's tailnet address with no `--accept-routes`
- [ ] `node_boot_time_seconds` stops moving. The real proof, and it is worth
      ~75 minutes of not rebooting before believing it.

## M2 - Operator, and kubectl without per-device setup

- [ ] `infra/platform/tailscale/`: namespace, HelmRepository
      (`https://pkgs.tailscale.com/helmcharts`), HelmRelease
      `tailscale-operator`, values, `operator-oauth.sops.yaml`
      (`client_id`/`client_secret`), kustomization
- [ ] `apiServerProxyConfig.mode: "true"` -- auth mode, which impersonates the
      calling Tailscale identity rather than forwarding as the operator
- [ ] RBAC: bind `florianzaruba@gmail.com` to a role. Without this the proxy
      connects and then denies everything, which reads like a broken proxy.
- [ ] `infra/platform/clusters/hetzner/tailscale.yaml` Flux Kustomization
- [ ] `tailscale configure kubeconfig <proxy-hostname>`; drop the
      `clusterconfig/kubeconfig` from daily use
- [ ] expose Grafana and `frontend-rw`/`frontend-ro`
- [ ] retire the `tunnel-hetzner` targets and `tunnel.sh`

## M3 - Close the door

- [ ] talosconfig endpoints to the nodes' tailnet addresses
- [ ] `bazel run //infra/tofu:apply -- -var="admin_access_enabled=false"`
- [ ] confirm 6443 and 50000 refused from off-tailnet -- invariant #4 is a
      testable claim, so test it

## M4 - Docs that currently say the wrong thing

- [ ] `infra/platform/tailscale/README.md` -- "Not configured yet", and the
      claim that the extension "sits idle". It does not sit idle; it reboots
      the cluster hourly. That sentence is why the cost stayed invisible.
- [ ] `infra/platform/README.md` -- component table, invariant #4
- [ ] `infra/doc/architecture.md` -- invariant #4 no longer relaxed
- [ ] `infra/doc/bootstrap-hetzner.md` -- the step that assumes no tailnet, and
      the break-glass path, which is where `--accept-routes` belongs
- [ ] Consider `infra/platform/tailscale/acl.hujson` synced from git, so the
      policy file stops being configuration that lives only in a web console

## Review

(to fill in)
