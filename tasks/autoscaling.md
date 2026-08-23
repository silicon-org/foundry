# Autoscale the build capacity

Plan of record. Supersedes `dedicated-migration.md`, which proposed buying one
large machine -- the opposite of what the utilisation data supports.

## Why

A week of CI, 100 runs, 2026-08-16 to 08-23:

| duration  | successful runs |
| --------- | --------------- |
| 0-1 min   | 13              |
| 1-3 min   | 35              |
| 3-6 min   | 4               |
| 6-12 min  | 1               |
| 12-30 min | 2               |
| >30 min   | 1               |

8.8 hours of CI wall time across six days. The cluster is idle ~94% of the
time, and 86% of successful runs finish inside three minutes because they are
cache walks: a representative run reported `6928 remote cache hit` against
**3 remote executions**.

So the machine is sized for a workload that occurs for minutes a day. A
dedicated box at EUR 166/month would have been ~6% utilised, and buying one
outright was worse still.

**The data is thin and worth saying so.** One person, working irregularly, and
this was the most intense week the repository has had -- infrastructure work
generating 14 runs a day. Normal cadence is lower, which makes utilisation worse
rather than better, so the conclusion holds in the direction that matters. What
the sample cannot tell us is how often the *heavy* tier will fire once RTL work
resumes in earnest. The design must therefore be cheap when idle rather than
tuned to a predicted rate.

## Two rules that fall out of how Hetzner bills

- **A stopped server still bills.** Scaling to zero means *deleting* it, so
  anything elastic must hold no state. The Buildbarn worker qualifies: emptyDir
  and a unix socket to its runner, no PVC.
- **The CAS never moves.** It is the value the cluster accumulates, and it stays
  on the always-on node's volume.

The tier sizing that used to be here was a guess. It has been replaced by
measured figures -- see "Target shape" below.

## Deciding what is "large"

Explicit rather than inferred. The heavy targets declare what they need:

```python
verilator_cc_library(
    name = "xs_cluster_verilated",
    exec_properties = {"size": "large"},
)
```

Buildbarn routes by platform properties, so `size=large` actions land in their
own queue and **cannot run at all** until a large worker exists. That makes
"queue non-empty" an unambiguous provisioning signal with nothing to infer.

Buildbarn's size classes (ISCC) were considered and rejected for now: they learn
from action *duration* and pick a class to optimise time, and our binding
constraint is memory. Right mechanism, wrong axis.

## Scaling, from parts that already exist

```
bb_scheduler queue depth (Prometheus)
   -> KEDA ScaledObject: worker Deployment (size=large) 0 -> N
   -> pods unschedulable (nodeSelector size=large)
   -> cluster-autoscaler, hetzner provider: creates a server
   -> Talos machine config delivered as cloud user-data
   -> node joins, worker registers, queue drains
```

No bespoke controller. The unknown is the last mile -- Talos taking its config
from user-data under cluster-autoscaler -- and that is what M1 exists to prove.

## Hysteresis

Billing is hourly, so a worker deleted at minute 12 and recreated at minute 25
costs two hours instead of one.

- **up**: immediately when the large queue is non-empty
- **down**: idle for N minutes **and** within the last ~10 minutes of a paid hour
- plus a cooldown, so a burst of pushes does not thrash

## The network constraint, measured

An earlier extrapolation here predicted ~230 MB/s at concurrency 16 and worried
about saturating a 1 Gbit link. Measured with the worker genuinely on its own
node at concurrency 6, the CAS moved **34 MB/s out and 17 MB/s in**, 6.8 GB over
an 18-minute build. Extrapolating the same way gives ~91 MB/s at concurrency 16
-- under the link, not past it.

So a local CAS cache on the elastic worker is not urgent. Revisit only if
concurrency goes well past 16 or the always-on node starts showing network wait.

## Prerequisite: the project server limit

Discovered while attempting M1. The cloud project refuses to create a fifth
server -- `resource_limit_exceeded` -- and not because of the size: a `cx23`,
the same type the control planes run, is refused identically. Four servers is
the ceiling today.

That is fatal to autoscaling rather than inconvenient. Ask Hetzner support to
raise the project limit, and ask for enough headroom to be worth having:

- **server count**: 10 or more, so several elastic workers can coexist with the
  permanent ones
- **dedicated vCPU (ccx)**: enough for the largest worker intended -- a ccx53 is
  32 -- since that class is often capped separately

Requested 2026-08-23, pending. Meanwhile the control planes have been collapsed
to one, which leaves two free slots -- enough to build and test everything below
except running more than one elastic worker at a time. So this blocks P4 at
scale, not P1 to P3.

## Target shape, derived from the measurements

| tier | machine | cost | runs |
|---|---|---|---|
| always-on | `cx43` -- 8 vCPU, 16 GB | **EUR 17.29/mo** | control plane, Buildbarn scheduler/CAS/frontends, monitoring, ARC controller **and runner**, portal, Tailscale operator, plus a small Buildbarn worker |
| elastic | `cx53` (16 vCPU, 32 GB, EUR 0.0511/h) or `ccx43` (16 dedicated, 64 GB, EUR 0.4781/h) | **EUR 0 when idle** | one Buildbarn worker, nothing else |

Today: `worker-1` is a `ccx33` at **EUR 149.71/month**, idle 94% of the time,
and too small for the one action that matters. Replacing it with `cx43` plus
20 elastic hours a month costs about **EUR 18-27**, an ~85% reduction, and
removes the ceiling at the same time.

**worker-1 is not needed.** Everything on it either belongs on the always-on
node or belongs on a machine that only exists while a build is running.

Three sizing facts decide the tiers:

- The heavy action peaks at **24.24 GiB**, so an elastic node needs 32 GB
  minimum and 64 GB for comfort. A `cx53` fits it because that node runs the
  worker and nothing else.
- The always-on tier is ~3.2 GiB of services plus etcd and the API server, plus
  **3 GiB for the ARC runner** -- which must be always-schedulable, because the
  runner is what executes `bazel` and therefore what *creates* the demand that
  triggers scaling. A node that has to scale up before the runner can start
  cannot bootstrap itself.
- A small always-on worker keeps the common case fast. A typical run executes
  three actions remotely; waiting 135 s for a machine to serve three actions
  would double the wall time of a two-minute build.

## Implementation

### P0 - Prerequisites

- [ ] Hetzner support: raise the project server limit (10+) and dedicated vCPU
      quota (32+). Four servers is today's ceiling and autoscaling cannot work
      inside it.
- [ ] `tofu apply -var="control_plane_count=1"` so state matches the two
      control planes already removed

### P1 - Replace worker-1 with a small always-on node

`worker-1` is a `ccx33` at **EUR 149.71/month**. It is idle 94% of the time and
cannot build the one action that matters -- 24.24 GiB needed against ~21
available -- so main's CI is red *with* it. Removing it loses nothing.

Add a node rather than resizing `cp-1`, which is a change from the earlier
sketch and cheaper in risk:

- no downtime; resizing would power off the cluster's only control plane
- etcd and the API server stay off the node that runs CI, which is the isolation
  the three-control-plane design was protecting and the only reason it existed
- reversible: add, migrate, delete, rather than mutate in place

It costs EUR 5.93/month more (`cp-1` stays a `cx23`) and uses a second permanent
slot, so until the limit is raised there is room for two elastic workers rather
than three. Both are noise against EUR 149.71.

- [ ] Create `foundry-worker-2` as a `cx43` (8 vCPU, 16 GB, EUR 17.29/mo), no
      user-data, then `apply-config` -- 135 s to Ready, measured
- [ ] Shrink the Buildbarn worker to fit 16 GB alongside the services and the
      ARC runner: concurrency 2, runner ~6 GiB. This is P2's small class arriving
      early, because a 20 GiB limit on a 16 GB node is a node-level OOM waiting
      for a build.
- [ ] Drain `worker-1`; watch the CAS volume detach and reattach -- the slowest
      and most failure-prone step
- [ ] Delete `worker-1`

Consequence to accept knowingly: heavy builds then need an elastic node, which
is manual until P3. CI stays red on that one action either way, so this changes
what it costs rather than whether it works. If the other 16 tests are wanted
green in the meantime, tag the heavy test `manual` until P3 lands.

### P2 - Two worker classes, scaled by hand

Shippable on its own: full capability, manual scaling.

- [ ] Split the worker Deployment in two:
      - `worker-small` -- always-on node, concurrency 2, ~4 GiB, platform
        `size=small`
      - `worker-large` -- `nodeSelector: pool=build`, concurrency 6, 44 GiB,
        platform `size=large`, and **`replicas` omitted from git** so Flux never
        owns that field and a scaler can
- [ ] `exec_properties = {"size": "large"}` on the heavy targets
- [ ] Verify a large action *queues* rather than landing on the small worker
- [ ] Document the manual path: create a node, `apply-config`, 135 s to Ready

### P3 - Automate provisioning

The one unsolved piece. `cluster-autoscaler` creates a server; something must
configure it, and **user-data does not work** (see M1).

- [ ] **Preferred: a pre-configured worker snapshot.** Boot a node from the base
      snapshot, apply the worker machine config, let it install, power off, take
      a snapshot. Servers created from *that* join with no configuration step at
      all, which removes the problem rather than working around it. A worker's
      config is generic -- the hostname comes from DHCP -- so one image serves
      every elastic node.
      Cost: the snapshot carries cluster secrets, so anyone with project access
      can mint a node that joins. Same boundary as user-data would have been,
      and it must be rebuilt when the cluster CA rotates.
- [ ] Fallbacks if that fails: diagnose user-data from the Hetzner console, or a
      controller that applies config to nodes sitting in maintenance mode.

### P4 - Close the loop

- [ ] KEDA `ScaledObject` on the scheduler's queue depth for `size=large`,
      driving `worker-large` replicas 0 -> N
- [ ] `cluster-autoscaler`, hetzner provider, node group `pool=build`, min 0,
      **max 2 as a cost guard**
- [ ] Scale-down only when idle *and* near the end of a paid hour
- [ ] Alert when the large queue is non-empty and no node arrives -- the failure
      mode is a build that hangs rather than fails, which looks like nothing

## Open questions

Answered by M1:

- ~~Is a 3-4 minute cold start acceptable?~~ It is 135 s, and yes.
- ~~Does the elastic worker need a local CAS cache?~~ Not at concurrency 6; 34
  MB/s measured against a 1 Gbit link.

Still open:

- How small can the always-on worker be before ordinary builds suffer? A typical
  run executes three actions remotely, so the answer is probably "very", but it
  has not been tested.
- Does a pre-configured worker snapshot actually boot and join, and does it
  survive a cluster CA rotation gracefully? This is P3 and it is the one piece
  with no evidence behind it yet.

## Review

(to fill in)
