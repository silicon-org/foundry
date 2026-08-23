# Move the cluster to one dedicated machine

Plan of record. Replace the four-node Hetzner Cloud cluster with a single
dedicated server, and tear the cloud down afterwards.

Why: `//hardware/soc/xs_cluster/tb:xs_cluster_verilated` is one Verilator
process over 139 MB of SystemVerilog and needs more than 20 GiB. Measured, not
estimated -- it was OOM-killed three times at a 20 GiB limit with a sampled peak
of 17.71 GiB, and the true peak has never been observed because every
measurement so far was truncated by the limit that killed it. A ccx33 cannot
hold it, and no flag makes the elaboration smaller: `--output-split` is already
set and bounds the C++ compiler, not Verilator.

Renting rather than buying: break-even on a second-hand box at home is 14-19
months at typical draw and tariff, colocation never pays off at all, and a
bought machine cannot scale to zero -- which is the direction
`tasks/` already points in. Hetzner's auction price is roughly what the
electricity alone would cost.

## The machine

Auction 3061038, FSN1-DC8, EUR 75.70/month excl. VAT.

| | |
|---|---|
| CPU | Xeon E5-1650 v3 -- **6 cores / 12 threads**, Haswell, 3.5 GHz |
| RAM | 128 GB DDR4 **ECC** registered (4x32) |
| Disk | **2 x 240 GB** SATA datacenter SSD |
| NIC | 1 Gbit Intel I210 |

Two things to be clear-eyed about.

**This is a CPU downgrade.** Six 2014-era cores against eight dedicated modern
ones. Per-core it is meaningfully slower. The reason it still wins is that
concurrency is currently throttled to **2 by memory**, not by cores -- with
128 GB it can go to roughly the thread count, so aggregate throughput should
improve substantially even though each action is slower. If builds feel slower
per-action afterwards, that is expected and is not a fault.

**Storage is the tight resource, not RAM.** 480 GB raw against 154 GiB of PVCs
today plus container images and Bazel's ephemeral churn -- the cloud worker is
using ~225 GiB of ephemeral on its own. It fits, but with less slack than the
RAM figure suggests, and the CAS ceiling is what to trim if it does not.

ECC is worth noting rather than passing over: for a machine whose job is 20 GiB
compiles, a silent bit flip surfaces as an unreproducible miscompile.

## Shape

One node, control plane and worker, `allowSchedulingOnControlPlanes: true`.
No hypervisor.

The control plane no longer has a machine of its own, so CI jobs share a kernel
with etcd and the API server. That is a real reduction and it is accepted here
rather than overlooked: fork pull requests never reach these runners, so
"untrusted" means a dependency inside a branch pushed by someone who already has
write access, and the pods are rootless under a `restricted` Pod Security
Standard. If that stops being good enough, the answer is two KVM guests on this
same box -- which is easier to add later than a hypervisor is to remove.

Disks are used separately rather than mirrored, since redundancy is explicitly
not wanted here:

| Disk | |
|---|---|
| sda | Talos system, container images, ephemeral |
| sdb | PVCs via local-path -- CAS, Prometheus, Loki, portal Postgres |

That split is also what keeps the cache's write churn off the disk etcd fsyncs
to.

## What this deletes

Three components stop having a job, and removing them is most of the work:

| Component | Why it goes |
|---|---|
| `hcloud` cloud controller manager | nothing to reconcile with one node and no cloud API |
| `hcloud` CSI + `hcloud-volumes` | Hetzner volumes attach to cloud servers only |
| private load balancer + `apiserver.tf` | one control plane; the node is the endpoint |
| `hcloud_firewall` | cloud firewalls do not apply to dedicated servers |

Replaced by: `local-path-provisioner` for PVCs, and Talos `ingressFirewall` plus
Tailscale for the network posture that `infra/tofu/network.tf` holds today.

Unchanged: talhelper, the patches, Flux, Buildbarn, ARC, monitoring, and the
Tailscale extension. This is a smaller system afterwards, not a differently
shaped one.

## M0 - Order and access

- [ ] Order auction 3061038; note the public IPv4 and the Robot credentials
- [ ] Confirm on arrival, before anything else:
      - [ ] `smartctl -a` on both SSDs -- these are used drives and a build cache
            is write-heavy; check `Percentage_Used` / host writes
      - [ ] `dmidecode -t memory` shows 4x32 GB ECC registered
      - [ ] `lscpu` confirms 6C/12T
- [ ] Robot: enable the rescue system, note the root password

## M1 - Talos on bare metal

- [ ] New schematic: drop `siderolabs/qemu-guest-agent` (no hypervisor), keep
      `tailscale` and `util-linux-tools`, add `siderolabs/intel-ucode`
- [ ] Boot rescue, write the raw image to the install disk, reboot into
      maintenance mode
- [ ] `talconfig.yaml`: one node, `controlPlane: true`,
      `allowSchedulingOnControlPlanes: true`, endpoint is the node itself
- [ ] Patches: keep `base.yaml`; replace `hetzner.yaml` with a `dedicated.yaml`
      that drops `externalCloudProvider` and the private-subnet nodeIP pin
- [ ] `ingressFirewall`: default deny, allow Tailscale's UDP 41641 and nothing
      else inbound. There is no break-glass firewall rule to fall back on here,
      so the tailnet is the only way in -- which is why the extension is
      configured in the same apply rather than afterwards.
- [ ] Second disk as a `userVolume` mounted for local-path
- [ ] `bazel run //infra/talos:genconfig`, apply, bootstrap etcd

## M2 - Platform

- [ ] Cilium (by hand, as today -- Flux cannot be scheduled without a CNI)
- [ ] `local-path-provisioner`, and make it the default StorageClass
- [ ] New cluster overlay `infra/platform/clusters/dedicated/`, selecting
      everything the hetzner one does **except** `hcloud.yaml`
- [ ] PVC sizes revisited against 240 GB rather than a cloud volume
- [ ] `sops-age` secret, then `flux bootstrap`

## M3 - CI cutover

- [ ] ARC scale set name: the old cluster's listener is registered for
      `foundry-hetzner-amd64`. Two clusters offering the same name split jobs
      unpredictably, so scale the old one to zero **before** the new listener
      registers.
- [ ] Cancel and re-dispatch anything queued -- a job is bound to a scale set
      session, and one that was addressed to the old cluster never arrives at
      the new one. This is already documented in `doc/bootstrap-hetzner.md`.

## M4 - Verify, and finally measure

- [ ] `bazel test //...` on `xs-cluster-tb` goes green
- [ ] **Measure the Verilator peak with a limit high enough not to truncate it.**
      This is the number the whole exercise has been missing. Set the runner
      limit to something generous (40 GiB) first, record the peak, then size the
      limit and `RUNNER_CONCURRENCY` from it.
- [ ] Untag the traced model if the measured peak leaves room for both
- [ ] Grafana, kubectl and talosctl reachable over the tailnet

## M5 - Tear down the cloud

Only after M4 passes. Nothing here is reversible.

- [ ] Confirm what `tofu destroy` takes with it: the servers, the primary IPs,
      the private network, the load balancer, **and the volumes** -- the CAS and
      Prometheus history included. Content-addressed cache is safe to lose; 15
      days of metrics is a judgement call, snapshot first if it matters.
- [ ] Remove the four old devices from the tailnet, and the `tag:foundry-cp` /
      `tag:foundry-worker` OAuth clients if the new node uses a single tag
- [ ] `bazel run //infra/tofu:destroy`
- [ ] Delete the Hetzner snapshot built by `//infra/talos:image`
- [ ] Decide whether the cloud project stays. Keeping it costs nothing and is
      where elastic workers would come from later -- but they would need a
      vSwitch to reach a dedicated node, which is the hybrid this migration
      exists to avoid. Worth writing down rather than rediscovering.

## M6 - Docs

- [ ] `infra/tofu/` -- most of it describes a cluster that no longer exists
- [ ] `doc/architecture.md` -- invariant #4 changes mechanism, and the
      control-plane/worker split is gone
- [ ] `doc/bootstrap-hetzner.md` -- replaced by a bare-metal equivalent
- [ ] `infra/platform/README.md` -- component table loses `hcloud/`
- [ ] `variables.tf`'s "scale by adding workers rather than growing this one" --
      the reasoning is sound and did not apply, because a single action's memory
      cannot be split across workers. Worth keeping with that exception stated.

## Review

(to fill in)
