# Monitoring

kube-prometheus-stack (Prometheus, Grafana, Alertmanager) with Loki for logs and
Grafana Alloy shipping them. Hetzner only: both Prometheus and Loki want a
PersistentVolume, the local cluster has no StorageClass, and metric history on a
cluster that `bazel run //infra/talos:down` deletes is history of nothing.

The reason this exists is one sentence from `../README.md`: *a cache with no
alerting fails silently*. Buildbarn can serve a 0% hit rate for a week and the
only symptom is that builds feel slow. ARC can wedge and jobs simply queue. The
default-deny policy on `arc-runners` is asserted by six paragraphs of comment and
was, until now, verified by nothing. Each of those is a claim this repository
makes about itself that it could not check.

## Getting in

```
bazel run //infra/platform/monitoring:tunnel-hetzner
```

Grafana on <http://localhost:3000>, Prometheus on 9090, Alertmanager on 9093.
The admin password is in `grafana-admin.sops.yaml`:

```
sops --decrypt infra/platform/monitoring/grafana-admin.sops.yaml
```

No Ingress, no LoadBalancer, no NodePort — invariant #4. Grafana is named in
`../tailscale/README.md` as something the operator will publish to the tailnet
once that exists; until then a port-forward is the whole access story, and
`networkpolicy.yaml` denies this namespace the internet in the other direction.

## What is scraped

| Target | How | Notes |
|---|---|---|
| Kubernetes control plane | chart | Talos needs three machine-config settings first; see `../../talos/README.md`. |
| Nodes | chart | node-exporter, which is why this namespace is PSS `privileged`. |
| Buildbarn (all six) | `scrape/buildbarn.yaml` | A PodMonitor: the worker has no Service and remote-asset's exposes only gRPC. |
| ARC controller + listener | `scrape/arc.yaml` | Off entirely without the `metrics:` block in `../arc/controller.yaml`. |
| Cilium, Hubble | `scrape/cilium.yaml` | Ports enabled in `../cilium/values.yaml`; the scrape objects deliberately are not. |
| Flux controllers | `scrape/flux.yaml` | `gotk-components.yaml` ships no monitor of its own. |
| Buildbarn portal | `scrape/bb-portal.yaml` | Already served metrics on 9980; nothing was reading them. |

Components own their metrics ports; this directory owns every scrape object.
That split is not stylistic. `../cilium/values.yaml` is also consumed by
`bazel run //infra/platform/cilium:bootstrap`, which runs against a brand-new
cluster with no CNI, no Flux and no Prometheus CRDs — a ServiceMonitor in there
would make a cluster's *first* install depend on a CRD that arrives four steps
later. The same holds for `../hcloud/`.

## Deriving a query rather than guessing one

Buildbarn's metric surface is not what a reader would assume, and the two
signals that matter most are the two that do not exist as their obvious name:

- **Cache hit rate** is a ratio over gRPC status codes, not a counter. A miss is
  `NotFound`, which is a legitimate answer rather than an error, so nothing
  counts it as one. See `buildbarn:action_cache_hit_rate:ratio30m` in
  `rules/buildbarn.yaml`.
- **Queue depth** is not exported at all. What is exported is how long tasks
  waited, as a histogram — which is the number anyone actually wants.
- **Worker count** is likewise a difference of two counters rather than a gauge.

Re-derive rather than trusting this file:

```
kubectl -n buildbarn port-forward svc/frontend-rw 9980
curl -s localhost:9980/metrics | grep '^# TYPE'
```

## Alerts fire, and go nowhere

Deliberate, and the honest half of this deployment.

The rules in `rules/` are evaluated by Prometheus and checked at commit time by
`bazel test //infra/platform:promtool_test` — because the operator's admission
webhook does catch a bad expression, but it catches it in a controller log
minutes after the push, attached to nothing.

The Alertmanager route points at a null receiver, which is the chart's default.
Wiring a real destination is an `alertmanager.config` block plus one SOPS
secret. The candidates and what each costs: a Slack webhook (good formatting,
easy to sleep through), ntfy or Pushover (actually wakes someone, needs a phone
app), SMTP (universal, and deliverability from a Hetzner IP is its own project).

`rules/capacity.yaml` covers only what the chart does not. kube-prometheus-stack
already ships `KubePersistentVolumeFillingUp`, `KubeNodeNotReady` and the
node-exporter alerts; restating those here would not add coverage, it would add
a second copy that drifts and a second page for the same event.

## One external check, off-cluster — still missing

The gap this file has always named, and it is still open.

Self-hosted monitoring cannot page you when the box it runs on is the thing that
died. The intended shape is a **dead man's switch** rather than a reachability
probe: Alertmanager's always-firing `Watchdog` alert pings an external service
every few minutes, and that service alerts when the pings *stop*. Keeping the
`Watchdog` rule is what makes this a one-URL change later.

It is the stronger form of the same idea. A reachability probe against a URL
notices the cluster being down. The dead man's switch notices that, and also
Prometheus being down, Alertmanager being down, and the whole stack having been
quietly broken by a bad values change — none of which a probe would see. It also
needs nothing public-facing, which a probe does, and which invariant #4 forbids.

## Where it runs

On the single worker, alongside the builds it watches, with
`priorityClassName: monitoring` so that eviction contests are decided the right
way round. That is not a permanent answer.

`allowSchedulingOnControlPlanes: false` in `talconfig.yaml` rules out the three
control planes, for a reason worth respecting — *a saturated node takes its
control plane with it*. That leaves one ccx33 whose memory limits already total
more than the node has, and the moment you most want Prometheus alive is the
moment a six-way parallel build is using what it was promised.

The sequence, deliberately in this order: ship co-tenant, run for two weeks,
record actual RSS and ingestion rate and volume growth, then size a small
`infra` node in `infra/tofu` and `talconfig.yaml` from data. A node bought before
the measurement is a guess with a monthly bill; the same node bought after is a
sized decision. `FoundryWorkerMemoryOvercommitted` in `rules/capacity.yaml` is
the signal that the wait is over.
