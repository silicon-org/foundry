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

## Milestones

### M1 - Prove the mechanism

**Attempted 2026-08-23. User-data does not deliver the machine config, and that
blocks the design until it is solved.**

| server | type | config delivery | result |
|---|---|---|---|
| foundry-worker-1 | ccx33 | `talosctl apply-config` by hand | works, in production |
| foundry-worker-2 | ccx43 | `--user-data-from-file` | Talos API never listens |
| foundry-worker-2 | ccx33 | `--user-data-from-file` | Talos API never listens |

Same snapshot, same generated config file, two server types -- so the variable
is user-data, not the machine. In both failures the host booted far enough to
take a private address and answer ICMP, but nothing ever listened on 50000. Not
maintenance mode either: from inside the private network the port was *closed*
while `10.0.1.11:50000` and `10.0.1.21:50000` answered from the same probe pod.
It never reached the tailnet, so the extension never started, so the
configuration never applied.

Why is not yet known, and the next step needs the Hetzner console -- an
interactive step. Worth checking there first:

- whether Talos panics or drops to maintenance without a listener
- whether it is mid-install: applying a config makes Talos install over the disk
  it booted from, and a failure there would look exactly like this
- whether the metadata service serves the user-data verbatim, or the CLI wraps it

If user-data cannot be made to work, the alternatives, cheapest first: a
controller that applies the config over the Talos API once a node boots into
maintenance mode (keeps `apply-config`, loses "no moving parts"); `talos.config=`
as a kernel argument, which needs a custom image or PXE; or SideroLink/Omni,
which is a much larger dependency.

- [ ] Establish why user-data does not apply, from the console
- [ ] **Measure cold start**: create -> boot -> join -> worker registers. The
      whole design assumes this is minutes, not tens of minutes. Not yet
      measured, because no elastic node has ever joined.
- [ ] Measure CAS throughput with the worker genuinely off-node

### M2 - Shrink the floor
- [ ] Control plane to one; `allowSchedulingOnControlPlanes: true`
- [ ] Everything always-on lands on that node
- [ ] Retire the private load balancer -- one control plane is its own endpoint
- [ ] Confirm the floor cost

### M3 - Routing
- [ ] `size=large` exec_properties on the heavy targets
- [ ] A second Buildbarn worker Deployment and platform queue for them
- [ ] Verify a large action queues rather than OOM-killing a small worker

### M4 - Automate
- [ ] KEDA on scheduler queue depth
- [ ] cluster-autoscaler with the hetzner provider
- [ ] Hour-boundary scale-down and cooldown
- [ ] An alert for a worker that fails to arrive -- the failure mode is a queue
      that never drains, which otherwise looks like a hung build

### M5 - Tear down what is left
- [ ] Delete the surplus control planes and the load balancer
- [ ] Keep the CAS volume and the snapshot; both are load-bearing here

## Open questions

- Is a 3-4 minute cold start acceptable for heavy builds? Probably yes at 10-30
  minute runtimes, but M1 measures it rather than assuming.
- How small can the always-on worker be before ordinary builds suffer?
- Does the elastic worker need a local CAS cache from the start, or only once
  concurrency rises?

## Review

(to fill in)
