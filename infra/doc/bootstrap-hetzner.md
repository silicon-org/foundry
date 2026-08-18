# Building the Hetzner cluster from nothing

The local runbook is four commands because Docker hands you a working machine.
This one is longer, and every extra step is either something a cloud makes you
do for yourself or a cycle that GitOps cannot break on its own.

About thirty minutes end to end, most of it waiting.

## Before you start

- **A dedicated Hetzner Cloud project**, and an API token for it with **Read &
  Write**. Dedicated because a project token is not scoped per resource type:
  the CSI driver's "manage my volumes" and "delete my servers" are the same
  permission, so the project boundary is the containment.
- **A passphrase for tofu state**, at least 24 characters.
- The age key at `~/.config/sops/age/foundry.txt`.
- A GitHub token with `repo` scope. `gh auth token` works.

Both secrets live in the login keychain, prompted so they never enter shell
history:

```
security add-generic-password -a foundry -s foundry-hcloud -U -w
security add-generic-password -a foundry -s foundry-tofu-state -U -w
```

Every command below reads them by name. Nothing prints them.

```
export TF_VAR_hcloud_token="$(security find-generic-password -w -s foundry-hcloud)"
export TF_VAR_state_passphrase="$(security find-generic-password -w -s foundry-tofu-state)"
export HCLOUD_TOKEN="$TF_VAR_hcloud_token"
```

## Check these first

Each of these cost an afternoon to discover, and each fails at apply time with
an error naming the symptom rather than the cause.

**Is the server type actually in stock?** Hetzner reports a type as
"unsupported location for server type" when it is merely sold out there, and
stock moves within minutes. `prices` in the API says where a type is *sold*;
availability is in `locations[].available`, which is what a create call
consults.

```
hcloud server-type describe ccx13 -o json \
  | jq -r '.locations[] | select(.available) | .name'
```

**Is there quota?** Dedicated (`ccx`) cores are metered against an account
limit that starts small — 8 on a new account, which one `ccx33` consumes
entirely. Shared (`cx`) instances count separately, which is why the control
planes are `cx23`. Exceeding it fails *partway through* apply, leaving whatever
was built before the failure.

**Does the snapshot fit?** A Hetzner snapshot inherits the disk of the machine
it was built on and cannot shrink, so it must be built on the smallest node type
in the cluster. `//infra/talos:image` builds on `cx23` (40 GB) for exactly this
reason. Raising that constant without raising the smallest node breaks apply
with "image disk is bigger than server type disk".

## 1. Build the boot image

```
bazel run //infra/talos:image
```

Resolves the schematic from `infra/talos/schematic.yaml`, checks that
`patches/hetzner.yaml` installs that same schematic, and builds a snapshot only
if one does not already exist. Prints the snapshot ID and nothing else on
stdout.

Building boots a throwaway server for a few minutes and costs a few cents. It is
idempotent: run it again and it reuses what it finds.

## 2. Provision

```
bazel run //infra/tofu:apply -- \
  -var="talos_snapshot_id=<ID from step 1>" \
  -var="admin_access_enabled=true" \
  -var="admin_ipv4=$(curl -s https://ifconfig.me)/32"
```

`admin_access_enabled` opens 6443 and 50000 to one address. It is needed here
because a node in maintenance mode has no tailnet yet, so something has to hand
it its first configuration. Step 8 closes it.

Read the plan rather than skimming it. Expect 16 resources and nothing
destroyed.

## 3. Configure the machines

The public addresses are Hetzner's choice, so take them from the output rather
than from the configuration:

```
bazel run //infra/tofu:apply -- -refresh-only   # or: tofu output
```

If `infra/talos/talsecret.sops.yaml` does not exist yet, create it once. Note
the pipe: the plaintext never touches disk.

```
bazel run -- @multitool//tools/talhelper gensecret \
| bazel run -- @multitool//tools/sops --encrypt --input-type yaml --output-type yaml \
    --filename-override infra/talos/talsecret.sops.yaml /dev/stdin \
> infra/talos/talsecret.sops.yaml
```

Then render and apply. The nodes are in maintenance mode, so this is `--insecure`:

```
bazel run //infra/talos:genconfig

for n in cp-1 cp-2 cp-3 worker-1; do
  bazel run -- @multitool//tools/talosctl apply-config --insecure \
    --nodes <public IP of $n> \
    --file infra/talos/clusterconfig/foundry-foundry-$n.yaml
done
```

`additionalApiServerCertSans` in `talconfig.yaml` holds the control-plane public
addresses. If the servers were rebuilt onto new primary IPs, update it before
generating, or kubectl over a public address will fail TLS verification while
talosctl keeps working — talosctl has its own CA, which is what makes the gap
easy to miss.

## 4. Start the cluster

```
bazel run -- @multitool//tools/talosctl \
  --talosconfig infra/talos/clusterconfig/talosconfig \
  --endpoints <cp-1 public IP> --nodes <cp-1 public IP> bootstrap
```

Watch etcd form. All three members should end up with `LEARNER=false` and peer
URLs on `10.0.1.x` — if the peer URLs are public addresses, the subnet pinning
in `patches/hetzner.yaml` is not taking effect and cluster traffic is about to
go somewhere it should not.

```
bazel run -- @multitool//tools/talosctl --talosconfig ... etcd members
```

Then fetch a kubeconfig. Its server is the private load balancer, which is not
reachable until Tailscale exists, so point it at a control plane's public
address for now:

```
bazel run -- @multitool//tools/talosctl --talosconfig ... \
  kubeconfig infra/talos/clusterconfig/kubeconfig --force
export KUBECONFIG=$PWD/infra/talos/clusterconfig/kubeconfig
```

## 5. Install the CNI

```
bazel run //infra/platform/cilium:bootstrap-hetzner
```

Not `:bootstrap`. That target passes only the shared values, which leave
`kubeProxyReplacement` off — correct where something else provides it, and here
Talos starts no kube-proxy at all. Using the wrong target produces a cluster
with no service networking that nevertheless looks healthy, because Cilium comes
up fine and simply is not doing that job.

Expect this to report `hubble-relay` not ready. That is the next step's problem,
not a failure.

## 6. Install the cloud controller manager

Nodes come up tainted `node.cloudprovider.kubernetes.io/uninitialized` and stay
that way until a CCM clears it. Flux's controllers do not tolerate that taint, so
they cannot be scheduled, so they cannot deploy the controller that would clear
it. Cilium escapes the same trap only because a CNI DaemonSet tolerates
everything.

So this one is installed by hand too. Mind the `tr -d '\n'`: the keychain adds a
trailing newline, and a 65-character token is rejected as containing invalid
characters.

```
security find-generic-password -w -s foundry-hcloud | tr -d '\n' \
| bazel run -- @multitool//tools/kubectl create secret generic hcloud \
    --namespace=kube-system --from-file=token=/dev/stdin --from-literal=network=foundry

bazel run //infra/platform/hcloud:bootstrap
```

Within a minute every node should be `Ready`, with a `hcloud://` provider ID and
no uninitialized taint.

## 7. Hand over to Flux

```
bazel run -- @multitool//tools/kubectl create namespace flux-system
bazel run -- @multitool//tools/kubectl -n flux-system create secret generic sops-age \
  --from-file=age.agekey=$HOME/.config/sops/age/foundry.txt

export GITHUB_TOKEN="$(gh auth token)"
flux bootstrap github --owner=silicon-org --repository=foundry --branch=main \
  --path=infra/platform/clusters/hetzner --personal=false
```

**Push your work first.** Flux reconciles what is on the remote, not what is on
your laptop, and a cluster that reconciles an older commit looks like a broken
cluster rather than an unpushed one.

Everything else — CSI, Buildbarn, ARC, the network policy — now arrives from
git. Flux adopts the two Helm releases installed above: same names, same
namespaces, same values, so its first reconcile is an upgrade rather than a
fight over ownership.

## 8. Close the door

```
bazel run //infra/tofu:apply -- \
  -var="talos_snapshot_id=<ID>" -var="admin_access_enabled=false"
```

Then confirm from off-tailnet that 6443 and 50000 are refused. Invariant #4 is a
testable claim, so test it rather than assuming it.

Until Tailscale is configured there is no other way in, so do this only once
something else can reach the cluster.

## Checking it worked

```
kubectl get nodes                       # 4 Ready, 3 control-plane
flux get kustomizations                 # 5, all Ready
kubectl -n buildbarn get pvc            # Bound, hcloud-volumes
cilium status                           # KubeProxyReplacement: True
```

Then the thing all of it exists for. Port-forward the read-write frontend and
run a real build:

```
kubectl -n buildbarn port-forward svc/frontend-rw 8981:8980 &
bazel test --config=hetzner --remote_executor=grpc://localhost:8981 //hardware/...
```

Cold, that is around 2700 remote actions and six minutes. Afterwards, check that
the cluster is unbothered: no new restarts, no `Unhealthy` events. A cluster that
completes a build and damages itself doing so is not one you can leave alone.

## Tearing down

```
bazel run //infra/tofu:apply -- -var="talos_snapshot_id=<ID>" -destroy
```

Servers, network, load balancer and primary IPs go. Two things deliberately do
not, because tofu never knew about them:

- **The Buildbarn volume**, created through a PersistentVolumeClaim by the CSI
  driver, whose StorageClass reclaims rather than deletes. This is the point:
  the next cluster starts with a warm cache instead of rebuilding everything.
- **The Talos snapshot**, which costs a couple of cents a month and saves
  several minutes.

Both must be deleted by hand when the cluster is retired for good:

```
hcloud volume list
hcloud image list --type snapshot
```

Rebuilding is this document from step 1, and step 1 will reuse the snapshot.
