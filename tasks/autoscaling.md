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

## Shape

| tier             | lives                                                                                                | sized for                                                 |
| ---------------- | ---------------------------------------------------------------------------------------------------- | --------------------------------------------------------- |
| always-on node   | control plane + scheduler, CAS, frontends, remote-asset, ARC, monitoring, portal, Tailscale operator | ~3.2 GiB measured steady state                            |
| always-on worker | small, permanent                                                                                     | the 3-minute cache-walk run, with no provisioning latency |
| elastic workers  | created and **deleted** on demand                                                                    | whatever the queued work needs                            |

Two rules that fall out of how Hetzner bills:

- **A stopped server still bills.** Scaling to zero means *deleting* it, so
  anything elastic must hold no state. The Buildbarn worker qualifies: emptyDir
  and a unix socket to its runner, no PVC.
- **The CAS never moves.** It is the value the cluster accumulates, and it stays
  on the always-on node's volume.

Keeping a small always-on worker rather than scaling to true zero is what stops
every push waiting three minutes for a machine before discovering it had nothing
to execute.

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

## The network constraint

Measured during a heavy build, at concurrency 2, with worker and CAS on the same
node: 25 MB/s in and 28.6 MB/s out of the CAS pod, and only 1.1 MB/s across
eth0 -- the traffic never left the host.

Move the worker to its own node and that becomes real network traffic. Scaled to
concurrency 16 it extrapolates to roughly 230 MB/s, past a 1 Gbit link. So
either the elastic worker runs a local CAS cache, or effective concurrency is
bounded by the network rather than by cores. Worth measuring properly the first
time a large worker runs, because it decides whether "just buy more cores"
actually buys anything.

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

M2 reduces the control planes to one, which frees two slots and would allow a
single elastic worker inside even the current limit. That is a reason to do M2
first, not a substitute for raising the limit.

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

### P1 - Collapse to one always-on node

Saves EUR 149.71/month on its own, and is worth doing whether or not the rest
lands.

- [ ] Resize `cp-1`: `cx23` -> `cx43` (`hcloud server change-type`, powers the
      server off, keeps the disk). Brief downtime.
- [ ] `allowSchedulingOnControlPlanes: true`, regenerate, apply
- [ ] Drain `worker-1`; confirm the CAS volume detaches and reattaches on the
      new node -- this is the step that can go slowly and is worth watching
- [ ] Delete `worker-1`

Accepted here, again: CI then shares a kernel with etcd. Fork pull requests
never reach these runners, the pods are rootless under `restricted`, and the
alternative is paying EUR 150/month for isolation on a machine that cannot run
the build anyway.

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

- Is a 3-4 minute cold start acceptable for heavy builds? Probably yes at 10-30
  minute runtimes, but M1 measures it rather than assuming.
- How small can the always-on worker be before ordinary builds suffer?
- Does the elastic worker need a local CAS cache from the start, or only once
  concurrency rises?

## Review

(to fill in)
