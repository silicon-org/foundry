# OpenTofu

Provisioning for the Hetzner cluster: private network, firewall, three control
planes, a build worker, and the load balancer that gives three control planes
one address.

x86, not arm64. The intent was Hetzner's cheap CAX line, and every CAX type was
out of stock in every location when this was built; see
`../doc/architecture.md`. Control planes are shared `cx` instances and the
worker is a dedicated `ccx`, which is a quota decision rather than a
performance one — dedicated cores are metered against a small account limit that
one build worker consumes entirely.

```
bazel run //infra/tofu:init
bazel run //infra/tofu:plan
bazel run //infra/tofu:apply
bazel run //infra/tofu:fmt -- -check
```

Two environment variables are required, and nothing runs without them:

```
export TF_VAR_hcloud_token=...       # Hetzner Cloud API token, read/write
export TF_VAR_state_passphrase=...   # encrypts state; stored beside the age key
```

The snapshot to boot comes from `bazel run //infra/talos:image`; pass it as
`-var="talos_snapshot_id=..."`.

## Why wrappers instead of just running `tofu`

Bazel *invokes* tofu at a pinned version. Bazel does not model tofu state, and
no `.tf` is generated from Starlark. That boundary is a non-goal in the spec
(§3) and it is what keeps this portable: tofu owns provisioning state, Flux and
Helm own manifests, Bazel owns only tool versions and hermetic entry points.

Consequently the wrappers `cd` into `$BUILD_WORKSPACE_DIRECTORY/infra/tofu`
before exec'ing tofu, so state and provider locks land in the source tree rather
than in a sandbox that gets discarded. See `tofu.bzl`.

## State is committed, because it is encrypted

State maps declared resources to real ones. Lose it and tofu cannot tell "create
this server" from "this server already exists", and recovery is `tofu import`
for every resource by hand. It also holds provider credentials in clear text by
default — which, combined with the wrapper keeping it in the source tree of a
*public* repository, is a real hazard rather than a theoretical one.

So `versions.tf` encrypts it: AES-GCM, with the key derived from a passphrase by
PBKDF2. The passphrase is supplied through `TF_VAR_state_passphrase` and never
enters the repository. What git sees is ciphertext, which makes committing it
the same kind of decision as committing a SOPS-encrypted secret — and buys
durability and history for nothing.

The protection that matters is against forgetting. `state_passphrase` has no
default, so tofu stops rather than falling back to plaintext, and `enforced =
true` prevents anyone quietly adding an unencrypted fallback later. Verify
rather than trust it: after the first apply, the canary is that no resource
value appears in `terraform.tfstate` — the file should be a `meta` block and an
`encrypted_data` string, nothing else.

What this does not provide is locking. Two concurrent applies would corrupt
state. That is acceptable for one operator and stops being acceptable the moment
CI applies infrastructure or a second person does; at that point this moves to a
backend that locks, and the encryption block travels with it unchanged.

## Talos arrives without configuration, on purpose

Servers boot the snapshot and wait in maintenance mode. Nothing here passes
`user_data`.

Machine configuration belongs to talhelper and contains cluster secrets; putting
it here would copy those into tofu state and collapse a boundary the
architecture deliberately keeps. Tofu owns machines and networks. `//infra/talos`
owns what runs on them.

The same reasoning explains `ignore_changes = [image]` on the servers. A new
schematic yields a new snapshot ID, and acting on that would replace every
control plane at once — an outage, not an upgrade. Talos upgrades in place with
`talosctl upgrade`, one node at a time.

## The firewall is closed, including to us

Hetzner firewalls filter the public interface only, so denying essentially all
inbound traffic costs the cluster nothing internally — the private network
carries etcd, the API server, kubelet and pod traffic regardless.

Two exceptions:

- **UDP 41641**, so Tailscale can establish direct connections. Without it peers
  fall back to DERP relays, which is fine for a shell and poor for a build cache
  moving large blobs. Nothing there authenticates by network position; it is a
  WireGuard endpoint, so unauthenticated packets are dropped by key.
- **`admin_access_enabled`**, off by default, which opens 6443 and 50000 to one
  address. This is invariant #6's break-glass path, and it is also how the
  cluster is built at all: a node in maintenance mode has no tailnet yet, so
  something has to hand it its first configuration. Dual-use, which is why it is
  a variable rather than a note in a runbook.

  No address is committed, and that is deliberate rather than an omission. An
  administrator's address is usually dynamic, so a rule pinned to whatever it
  was on the day it was written has gone stale by the time anyone reaches for
  it — during the outage it was supposed to cover. Open it at the moment of use
  instead:

  ```
  bazel run //infra/tofu:apply -- \
    -var="admin_access_enabled=true" \
    -var="admin_ipv4=$(curl -s https://ifconfig.me)/32"
  ```

  Close it the same way, with `admin_access_enabled=false`, and confirm from
  off-tailnet that 6443 and 50000 are refused. This path works during a tailnet
  outage because the Hetzner API is a separate control plane: it does not depend
  on the cluster, the VPN, or whatever else has broken.

  Resisted deliberately: an `http` data source that looks the address up on
  every apply. It would keep itself current, and it would also mean the firewall
  silently changes based on where the apply ran from — including from CI.

The load balancer has no public interface for the same reason. Hetzner load
balancers cannot have a firewall attached, so a public one would put the
Kubernetes API on the open internet with nothing in front of it. It is reachable
because the Talos Tailscale extension advertises the private network as a
tailnet route.
