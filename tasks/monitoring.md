# Monitor the cluster: Prometheus, Loki, Grafana

Plan of record for the `monitoring` branch. This is the checklist; the reasoning
that makes each item arguable is written beside it, because a monitoring stack
assembled from defaults is how you end up with four hundred metrics and no
answer to the only question that matters.

Why: `infra/platform/README.md` already names this "the next real gap", and the
sentence it uses is the whole justification — *a cache with no alerting fails
silently*. Buildbarn can serve a 0% hit rate for a week and the only symptom is
that builds feel slow. ARC can wedge and jobs simply queue. The Cilium
default-deny on `arc-runners` is asserted by six paragraphs of comment and
verified by nothing. Each of those is a claim this repository makes about
itself that it currently cannot check.

Scope decisions taken before starting, so they are not re-litigated mid-way:

| Decision | Choice | Why |
|---|---|---|
| Clusters | **Hetzner only** | Same precedent as `bb-portal`. The local cluster has no StorageClass and `bazel run //infra/talos:down` deletes it, so its metric history is history of nothing. A `clusters/local/` overlay stays possible; nothing here forecloses it. |
| Log storage | **Filesystem PVC on `hcloud-volumes`** | Loki `SingleBinary`, ~7d retention. No new credential, no bucket in OpenTofu, one moving part. Object storage is the right answer at ten times this size, not at this one. |
| Alert delivery | **Stubbed** | Rules ship and are validated; the route points at a null receiver. Wiring a destination is a values change and a SOPS secret, deliberately deferred rather than guessed at. |
| Off-cluster check | **Deferred** | The gap `infra/platform/monitoring/README.md` already names stays named. M8 records what it should be so the follow-up is not a fresh design. |

---

## M0 — Scaffolding

- [x] `infra/platform/monitoring/` with `kustomization.yaml`, `namespace.yaml`,
      `BUILD.bazel` (`manifests` filegroup), and the `HelmRepository` objects
- [x] `infra/platform/clusters/hetzner/monitoring.yaml` — the Flux
      `Kustomization`. `dependsOn: [hcloud]`, because every persistent piece
      here needs a StorageClass, exactly like `bb-portal`
- [x] Register both new kustomize roots in `KUSTOMIZE_ROOTS` in
      `infra/platform/BUILD.bazel`, and add the filegroup to the test's `data`
- [x] Pin the chart versions rather than tracking latest. Derive, do not guess:
      `helm search repo prometheus-community/kube-prometheus-stack --versions`
      and the same for `grafana/loki` and `grafana/alloy`
- [x] **Gate:** `bazel test //infra/platform:kustomize_test` passes with the new
      roots rendering, before anything is pointed at a cluster

### The namespace is `privileged`, and that is a real cost

`node-exporter` needs `hostNetwork` and `hostPID`, which are Pod Security
Standards *baseline* violations, not merely `restricted` ones. So the monitoring
namespace cannot carry the `restricted` label that `arc-runners` does, and
labelling it `baseline` does not help either.

Two honest options, and the second is only better if the first is measured to
be a problem:

1. One `monitoring` namespace at `privileged`, with a CiliumNetworkPolicy doing
   the containment instead of PSS. Node metrics genuinely require node access;
   pretending otherwise means either no node metrics or a lie in a label.
2. `node-exporter` alone in its own `privileged` namespace, everything else in a
   `restricted` one. More correct, two more objects, and the blast radius it
   reduces is a DaemonSet that upstream publishes and everyone runs.

Take (1), write down that it was a choice, and let the network policy be the
control. Do not label it `restricted` and disable node-exporter — losing node
metrics on a four-node cluster to satisfy a label is the wrong trade.

---

## M1 — kube-prometheus-stack, scraping Kubernetes

- [x] `HelmRepository` → `https://prometheus-community.github.io/helm-charts`
- [x] `HelmRelease` `kube-prometheus-stack`, values in a `ConfigMap` generated
      from `values.yaml` with `disableNameSuffixHash: true`, following the
      `cilium/` pattern and for the same reason
- [x] `install.crds: CreateReplace` / `upgrade.crds: CreateReplace`. These CRDs
      are large enough that a naive `kubectl apply -f` fails on the 262144-byte
      annotation limit; helm-controller does not take that path, which is worth
      knowing before someone "helpfully" applies them by hand
- [x] Flux `Kustomization` `timeout: 15m`. `wait: true` on a chart this size
      against a cold image cache will otherwise report a failure that is only
      slowness

### The one setting that silently discards half this work

```yaml
prometheus:
  prometheusSpec:
    serviceMonitorSelectorNilUsesHelmValues: false
    podMonitorSelectorNilUsesHelmValues: false
    ruleSelectorNilUsesHelmValues: false
    probeSelectorNilUsesHelmValues: false
    scrapeConfigSelectorNilUsesHelmValues: false
```

- [x] Set all five

Left at their defaults, the operator only adopts objects labelled with this
Helm release. Every `ServiceMonitor`, `PodMonitor` and `PrometheusRule` written
in M3 and M5 is then ignored — not rejected, ignored. Nothing logs an error,
Prometheus simply has no such target, and the symptom is an empty graph that
looks like the exporter is broken. This is the single most expensive default in
the chart.

### Retention

- [x] `retention: 15d` **and** `retentionSize: 40GiB`, on a 50Gi
      `hcloud-volumes` claim

Both, not either. Time-based retention alone means a cardinality mistake fills
the volume and Prometheus crash-loops; size-based retention alone means a quiet
week silently keeps a year. `retentionSize` is the guard that keeps the failure
recoverable.

- [ ] **Gate:** `up == 1` for every job the chart creates except the ones M2 is
      about, and `kubectl -n monitoring get prometheus,alertmanager` reports
      ready replicas

---

## M2 — Make Talos expose what Kubernetes hides

The stack ships `ServiceMonitor`s for the control plane, and on Talos three of
them find nothing. Each fails the same way — a target that is permanently down,
which people learn to ignore, which is how a monitoring system starts lying.

- [x] `kube-controller-manager` and `kube-scheduler` bind to `127.0.0.1` by
      default. Add to `infra/talos/patches/hetzner.yaml`:

      ```yaml
      cluster:
        controllerManager:
          extraArgs: {bind-address: 0.0.0.0}
        scheduler:
          extraArgs: {bind-address: 0.0.0.0}
      ```

      Then set `kubeControllerManager.service.port/targetPort: 10257` and
      `kubeScheduler.*: 10259`, both with `serviceMonitor.https: true` and
      `insecureSkipVerify: true` — those components serve self-signed certs and
      the cluster CA does not cover them.

- [x] Confirm 10257/10259 are **not** reachable from outside. The Hetzner
      firewall in `infra/tofu` allows one administrative address to 6443 and
      50000 and nothing else, so this should already be true — but "should
      already be true" is exactly the phrasing that precedes an exposure.
      Verify it against the applied firewall, not against the file.

- [x] etcd. Add to `infra/talos/patches/hetzner-controlplane.yaml`:

      ```yaml
      cluster:
        etcd:
          extraArgs: {listen-metrics-urls: http://0.0.0.0:2381}
      ```

      then `kubeEtcd.service.port/targetPort: 2381` with
      `serviceMonitor.scheme: http`. This is etcd's dedicated metrics listener:
      it serves `/metrics` and `/health` and nothing else, which is what makes
      an unauthenticated listener acceptable here. The alternative is mounting
      etcd client certificates into Prometheus, which gives a scrape job the
      credentials to read the whole cluster's secrets in order to draw a graph.

- [x] `kubeProxy.enabled: false`. Talos never starts one on this cluster
      (`cluster.proxy.disabled` in `patches/hetzner.yaml`), so the default
      `ServiceMonitor` is a target that can never come up.

- [x] Talos itself exports no Prometheus endpoint, and this is not an oversight
      to fix later. Node-level signal comes from `node-exporter`; Talos-level
      signal comes from `talosctl`. Write that down in the README so the
      question is answered once.

- [x] Machine config changes take a `bazel run //infra/talos:genconfig` and a
      rolling `talosctl apply-config`, one node at a time. This milestone
      touches the control plane, so it is the one place in this plan where a
      mistake costs more than a dashboard.

- [ ] **Gate:** zero permanently-down targets in
      `kubectl -n monitoring port-forward svc/…-prometheus 9090` → Status →
      Targets. Not "few". Zero, or an explicit written reason.

---

## M3 — Scrape the things this cluster actually exists for

Kubernetes health is table stakes. These are the signals
`infra/platform/monitoring/README.md` asks for.

### Buildbarn

Every component already sets `enablePrometheus: true` on a diagnostics HTTP
server at `:9980` (`config/common.libsonnet`), so most of this is plumbing that
already exists and is unscraped.

- [x] Verify each component's jsonnet actually includes `global: common.global`
      — `storage`, `scheduler`, `frontend-ro`, `frontend-rw`, `worker`,
      `remote-asset`. One that does not is one that silently has no metrics.
- [x] `worker` has no Service and `remote-asset`'s exposes only gRPC 8985. Use a
      `PodMonitor` over `app in (storage, frontend-ro, frontend-rw, scheduler,
      worker, remote-asset)` rather than inventing Services nothing else needs —
      and add a named `metrics` containerPort to the `worker` and `remote-asset`
      pods so the monitor can select by name instead of by number.
- [x] Derive the metric names against a live instance rather than from memory:
      `kubectl -n buildbarn port-forward deploy/storage 9980` then
      `curl -s localhost:9980/metrics | grep -oE '^buildbarn_[a-z_]+' | sort -u`.
      The three that matter and the shape each is expected to take:
      - **Cache hit rate** — ratio of `grpc_code="OK"` to total on `Get`
        operations against the `ac` storage type, from
        `buildbarn_blobstore_blob_access_operations_duration_seconds_count`.
        A miss is `NotFound`, not an error, which is why this is a ratio over
        labels rather than a counter someone thought to export.
      - **Queue depth and wait** — the scheduler's in-memory build queue series.
      - **Worker saturation** — executing versus idle workers per platform
        queue, which is the number that says whether `RUNNER_CONCURRENCY: 6` is
        right for a ccx33.
- [x] The `buildbarn` namespace has no ingress restriction — its only
      CiliumNetworkPolicy selects `app: remote-asset` and sets
      `enableDefaultDeny.ingress: false` — so scraping needs no change there.
      Confirm rather than assume; this is the kind of fact that changes.

### ARC

- [x] Listener metrics are **off unless asked for**. Add to `arc/controller.yaml`:

      ```yaml
      metrics:
        controllerManagerAddr: ":8080"
        listenerAddr: ":8080"
        listenerEndpoint: "/metrics"
      ```

      Without this block there are no `gha_*` series at all, which is precisely
      the "runner pod lifecycle, queue wait time" the README asks for.
- [x] Find where the listener pod actually lands:
      `kubectl get pods -A -l app.kubernetes.io/component=runner-scale-set-listener`.
      If it is in `arc-runners`, that namespace's `ingress: []` default-deny
      blocks the scrape, and the fix is a narrow exception for the monitoring
      namespace on the metrics port only — not a relaxation of the policy.
- [x] `PodMonitor` for controller and listener.

### Cilium and Hubble

- [x] Enable the metrics endpoints in `cilium/values.yaml`:

      ```yaml
      prometheus: {enabled: true}                 # agent      :9962
      operator: {prometheus: {enabled: true}}     # operator   :9963
      hubble:
        metrics:
          enabled:
            - "drop:sourceContext=namespace;destinationContext=namespace"
            - dns
            - tcp
            - flow
      ```

      The label context on `drop` is not decoration. Without it,
      `hubble_drop_total` has no namespace dimension and the question the README
      actually asks — *are flows from `arc-runners` being dropped?* — cannot be
      expressed as a query.

- [x] **Do not set `serviceMonitor.enabled` in Cilium's values.** Write the
      `ServiceMonitor` objects in `monitoring/` instead.

      This is the important one. `cilium/values.yaml` is consumed twice, by
      design: by the Flux `HelmRelease` and by
      `bazel run //infra/platform/cilium:bootstrap`, which runs against a
      brand-new cluster that has no CNI, no Flux, and no Prometheus CRDs.
      Putting a `ServiceMonitor` in those values makes a cluster's very first
      helm install depend on a CRD that arrives four steps later. The same
      argument applies to `hcloud/`, also bootstrap-installed: monitoring owns
      the scrape objects, components own only their metrics ports.

### Flux and the portal

- [x] `PodMonitor` for the Flux controllers in `flux-system` (`:8080`). The
      upstream `gotk-components` manifest does not include one.
- [x] `bb-portal`'s Service already publishes `metrics` on 9980. One
      `ServiceMonitor`, and its network policy already leaves ingress open.

- [ ] **Gate:** one PromQL expression per signal, run against the live
      Prometheus and recorded in the README with its output. A dashboard panel
      is not evidence that a metric exists; a query returning a number is.

---

## M4 — Logs

- [x] `HelmRepository` → `https://grafana.github.io/helm-charts`
- [x] `HelmRelease` `loki`, `deploymentMode: SingleBinary`,
      `singleBinary.replicas: 1`, `loki.storage.type: filesystem`,
      `loki.auth_enabled: false`, `commonConfig.replication_factor: 1`,
      TSDB schema `v13`, persistence on `hcloud-volumes`, 30Gi
- [x] **Turn off the caches.** `chunksCache.enabled: false`,
      `resultsCache.enabled: false`. Both default to *on* and request several
      gigabytes of memcached apiece — on this cluster that is more memory than
      the thing they accelerate. Also `lokiCanary.enabled: false` and
      `test.enabled: false`.
- [x] Retention: `limits_config.retention_period: 168h`,
      `compactor.retention_enabled: true`,
      `compactor.delete_request_store: filesystem`. Without the compactor
      settings the retention period is a value nothing acts on and the volume
      fills anyway.
- [x] Shipping is **Grafana Alloy**, not Promtail. Promtail reached end of life
      in February 2025; starting a new deployment on it is starting in arrears.
      DaemonSet, tailing `/var/log/pods`, relabelled to carry namespace, pod and
      container.
- [ ] **Gate:** kill a Buildbarn worker pod and find its last log lines in
      Grafana by namespace and pod, after the pod object is gone. That is the
      whole point — logs that only exist while the pod does are `kubectl logs`
      with extra steps.

---

## M5 — Dashboards and alert rules

### Dashboards are files, not clicks

- [x] `grafana.persistence.enabled: false`, dashboards from ConfigMaps labelled
      `grafana_dashboard: "1"`, picked up by the sidecar; datasources
      provisioned from values.

Stateless on purpose, and it follows directly from this repository's existing
rule that nothing is configured by hand. A dashboard edited in the UI is lost on
the next pod restart — which is a feature, because the alternative is a
dashboard nobody can review, diff, or rebuild. Export the JSON, commit it, let
Flux put it back.

- [x] Admin credentials from a SOPS secret via `grafana.admin.existingSecret`,
      and the Flux `Kustomization` gets the `decryption` block, same as `arc/`.
- [x] Vendored, committed as JSON: node-exporter (ships with the stack), Cilium
      and Hubble, Flux. Pin and commit rather than referencing a `gnetId` —
      a dashboard fetched at runtime is an unpinned dependency with a network
      call in front of it.
- [x] Hand-written, because nobody publishes one: **Buildbarn** (hit rate, queue
      depth, worker saturation, action duration percentiles) and **ARC** (queue
      wait, runners running versus desired, pod lifecycle).

### Rules

- [x] `PrometheusRule` objects, grouped by what they say rather than by which
      exporter they came from:
      - Buildbarn: cache hit rate collapsed; queue depth sustained above
        workers × concurrency; no workers registered for a platform queue;
        scheduler or storage down
      - ARC: jobs assigned but no runner started within N minutes — the failure
        mode the runner-image pin comment in `arc/runner-scale-set.yaml`
        describes, which today is invisible
      - Cilium: any dropped flow with `source_namespace="arc-runners"`. Note the
        inversion worth stating: on this one, *zero* drops over a long window is
        also suspicious, because a default-deny policy that never denies
        anything is usually a policy that is not applied
      - Capacity: PVC projected to fill (Buildbarn cache, Prometheus, Loki,
        Postgres), node memory and disk, node not ready
      - Flux: reconciliation failing or suspended
- [x] Route everything to a `null` receiver. Keep the chart's always-firing
      `Watchdog` rule — M8 needs it.
- [x] Validate rules **at commit time, not at reconcile time**. Pin `promtool`
      in `//tools` and add a `sh_test` beside `kustomize_test`, for the reason
      `kustomize_test.sh` already gives in its header comment: the operator's
      admission webhook does catch a bad rule, but it catches it in a controller
      log minutes after the push, attached to nothing.
- [ ] **Gate:** deliberately break something small — scale `storage` to zero —
      and watch the intended alert fire and resolve. An alert that has never
      fired is a hypothesis.

---

## M6 — Access

- [x] `monitoring/tunnel.sh` + `//infra/platform/monitoring:tunnel-hetzner`,
      reusing the `buildbarn/tunnel.sh` shape (it already takes
      `namespace/service:local:remote` specs and picks the right kubeconfig).
      Grafana on 3000, Prometheus on 9090, Alertmanager on 9093.
- [x] No Ingress, no LoadBalancer, no `NodePort`. Invariant #4, and Grafana is
      explicitly named in `tailscale/README.md` as something the operator will
      expose once the tailnet is configured. Until then it is a port-forward.
- [x] CiliumNetworkPolicy for the namespace. Egress: kube-dns, the API server
      (`toEntities: [kube-apiserver]`), kubelet and node-level exporters
      (`toEntities: [host, remote-node]` — node-exporter and the Cilium agent
      are on host network, so a pod selector cannot reach them), and the
      specific pods and ports scraped in M3. No internet: nothing here has any
      business making an outbound call, and a Grafana that cannot reach the
      internet cannot fetch a plugin at runtime either, which is the same
      pinning argument as above.
- [x] Leave ingress default-deny off, as `bb-portal` does, and for the same
      reason: `kubectl port-forward` arrives from the node, and ports are the
      control here rather than source.

---

## M7 — Where it runs, decided from measurement

**There is currently no room for this stack, and that needs saying plainly
before it is deployed rather than after.**

`allowSchedulingOnControlPlanes: false` in `talconfig.yaml`, with a rationale
worth respecting: *a saturated node takes its control plane with it, and build
workloads are exactly the kind that saturate one*. So the three cx23 control
planes are out. That leaves one ccx33 worker, whose Hetzner overlay already
commits it:

| | CPU requests | Memory limits |
|---|---|---|
| Buildbarn worker | 1 | 4Gi |
| Buildbarn runner | 4 | 20Gi |
| ARC runners (2 × max) | 1 | 6Gi |
| **Total** | **6 of 8** | **30Gi of 32** |

Scheduling goes by requests, and memory requests on that node are only ~2.5Gi,
so the stack will schedule. It will also be the thing that loses when a
six-way parallel build takes the node to its limits — and Prometheus getting
OOM-killed mid-build is precisely the moment you wanted it.

- [ ] Ship co-tenant on the worker first, with honest `requests` and a
      `priorityClassName` above the build workloads so eviction contests are
      decided the right way. This is the cheap, reversible step and it produces
      the numbers the next one needs.
- [ ] Run for two weeks. Record actual Prometheus RSS, ingestion rate, active
      series, Loki RSS, and volume growth per day.
- [ ] Then decide from data, not from this table: add an `infra_count` /
      `infra_type` pair to `infra/tofu/variables.tf` and a matching
      `hcloud_server` (a cx32-class node, ~€8–14/month, not a second ccx33), a
      node entry in `talconfig.yaml`, and Talos `nodeLabels` + `nodeTaints` so
      monitoring lands there and build workloads do not.

Sequenced this way on purpose. A node bought before the measurement is a guess
with a monthly bill; the same node bought after is a sized decision. And the
measurement is worth having regardless — "is remote execution paying for
itself" is the question this cluster exists to answer, and it is unanswerable
today.

- [ ] **Gate:** a full `bazel test --config=hetzner //...` run with monitoring
      deployed, showing no monitoring pod restarted and no build action slower
      than the same run without it.

---

## M8 — Written down, deliberately not built

Both were considered and deferred. Recorded here so the follow-up is an
implementation rather than a fresh design.

- [ ] **Alert delivery.** The route points at a null receiver. Wiring a real one
      is an `alertmanager.config` change plus one SOPS secret. The candidates
      and what each costs: a Slack incoming webhook (good formatting, easy to
      sleep through), ntfy or Pushover (actually wakes someone, needs a phone
      app), SMTP (universal, and deliverability from a Hetzner IP is its own
      project).
- [ ] **The off-cluster dead man.** `infra/platform/monitoring/README.md`
      describes this as a reachability check, and a dead-man's-switch is the
      stronger form of the same idea: Alertmanager's always-firing `Watchdog`
      alert pings an external URL every few minutes, and the external service
      alerts when the pings *stop*. That covers the cluster being down, but also
      Prometheus being down, Alertmanager being down, and the whole stack having
      been quietly broken by a bad values change — none of which a reachability
      probe against a URL would notice. It also needs nothing public-facing,
      which a reachability probe does, and which invariant #4 forbids.
      Keeping the `Watchdog` rule in M5 is what makes this a one-URL change.

---

## Finally — say what is true

The documentation in this repository describes monitoring in the present tense
in three places. Once the above is deployed, two of them become true and one
still needs qualifying.

- [x] `infra/platform/monitoring/README.md` — rewrite from stub to what is
      deployed. Keep the "one external check, off-cluster" section and mark it
      as the outstanding gap it still is.
- [x] `infra/platform/README.md` — move `monitoring/` from the "not deployed"
      table to the deployed one.
- [x] `infra/doc/architecture.md` — its "Access and monitoring" section already
      claims kube-prometheus-stack and Loki. Make it accurate about what is
      scraped, and about the external check still being absent.
- [x] `infra/talos/README.md` — the control-plane and etcd metrics changes from
      M2 are machine-config decisions and belong beside the others.

---

## Traps, collected

Every one of these fails quietly rather than loudly, which is why they are a
list rather than prose.

1. `serviceMonitorSelectorNilUsesHelmValues` — hand-written monitors are
   ignored, not rejected. Costs a day.
2. Talos binds controller-manager and scheduler to loopback; etcd metrics need a
   separate listener. Three permanently-down targets, which people learn to
   scroll past.
3. Cilium's values file is consumed by a **pre-Flux bootstrap install** on a
   cluster with no CRDs. A `ServiceMonitor` in there breaks cluster creation,
   not monitoring.
4. ARC exports no listener metrics without an explicit `metrics:` block.
5. `hubble_drop_total` without `sourceContext=namespace` cannot answer the one
   question Hubble was enabled for.
6. Loki's chart enables memcached by default and asks for gigabytes.
7. `retention` without `retentionSize` turns a cardinality mistake into a
   crash-loop; the compactor settings turn Loki's retention from a value into a
   behaviour.
8. Promtail is end-of-life. Use Alloy.
9. The monitoring namespace cannot be PSS `restricted` while node-exporter is in
   it. Choose deliberately; do not discover it at deploy time.
10. `kubectl apply -f` on the stack's CRDs exceeds the annotation size limit.
    helm-controller is fine; a helpful human is not.

---

## Review — what the implementation changed about the plan

Everything that can be built without a running stack is built and tested;
`bazel test //infra/...` passes, including a new `promtool_test`. The eleven
boxes still open are all gates that need the stack deployed, plus M7's two-week
measurement and M8's deliberate deferrals.

Ten things turned out differently from the plan. Each was found by checking
against the live cluster or the actual chart rather than against the
documentation, and each would have been a silent failure.

1. **etcd cannot be found by selector, and no machine-config change fixes
   that.** Talos runs etcd as a Talos service, not a mirrored static pod, so
   there is no Pod object in `kube-system` for the chart's Service to select and
   it would have had zero endpoints regardless of `listen-metrics-urls`. Fixed
   with `kubeEtcd.endpoints`, naming 10.0.1.11–13 explicitly — the one place a
   change to `control_plane_count` must be mirrored by hand.

2. **Cilium's `prometheus.enabled` does not create a Service.** The chart
   renders `cilium-agent` and `cilium-operator` only when
   `serviceMonitor.enabled` *or* `metricsService` is set. Since the first is
   forbidden here (bootstrap runs against a CRD-less cluster), enabling the
   ports alone would have opened two endpoints with nothing in front of them —
   and a ServiceMonitor selecting a Service that was never created reports no
   error at all. `metricsService: true` on both.

3. **The plan's Buildbarn queries do not exist.**
   `buildbarn_blobstore_blob_access_operations_duration_seconds_count` is not a
   metric. Derived from a live instance instead: hit rate is a ratio over
   `grpc_server_handled_total` (`OK` versus `NotFound` on `GetActionResult`),
   queue depth is not exported at all and the usable signal is the
   `tasks_queued_duration_seconds` histogram, and worker count is a difference
   of two counters rather than a gauge.

4. **The ARC listener runs in `arc-systems`, not `arc-runners`.** So no hole in
   that namespace's default-deny policy is needed — the concern the plan raised
   is simply absent. Its port is selected by number rather than name, because
   the listener pod is built by the controller at runtime rather than rendered
   by the chart.

5. **The `bb-portal` Service carried no labels.** A ServiceMonitor selects
   Services by their own labels, not by their pod selector, so the monitor would
   have matched nothing. Added `app: bb-portal` to the Service.

6. **etcd's chart defaults were already right** (port 2381, scheme http), so M2
   is one machine-config change rather than two plus values. Confirmed 10250 is
   filtered from the internet on a control plane's public address, which is the
   empirical form of the firewall check M2 asked for.

7. **Alloy would have re-shipped every log on every restart.** The chart runs it
   with `--storage.path=/tmp/alloy` and a read-only root filesystem, and mounts
   nothing there. Not a crash — a duplicate day of logs per restart. Added an
   emptyDir. The chart also already injects `K8S_NODE_NAME`, so the plan's extra
   env var was redundant.

8. **Loki's chart guards its own ServiceMonitor on the CRD existing at render
   time**, which helm-controller evaluates against the live cluster. Without
   `dependsOn: kube-prometheus-stack` a first install silently omits it, forever.
   Alloy's chart does *not* guard, so the same ordering turns a silent omission
   into a loud failure that never happens.

9. **Trap #10 landed on our own dashboards.** Cilium's agent dashboard is 280KB,
   past the 262144-byte last-applied-configuration annotation limit. Flux applies
   server-side and is unaffected; `kubectl apply -f` is not. Each vendored
   dashboard now gets its own ConfigMap so that limit stays a property of one
   known file. Verified both apply modes against the live API server.

10. **The generic capacity alerts in M5 were already shipped by the chart.**
    `KubePersistentVolumeFillingUp`, `KubeNodeNotReady` and the node-exporter
    alerts all exist upstream. `rules/capacity.yaml` was cut down to the two
    things that are specific to this cluster: no schedulable worker, and memory
    limits on the worker climbing past 150% of the node.

Smaller deviations worth recording:

- **One kustomize root, not two.** `bb-portal` is the precedent: a Hetzner-only
  component whose Flux `Kustomization` points straight at the component
  directory, with no overlay.
- **`tunnel.sh` moved to `infra/platform/`.** Two packages use it now, so it is
  cluster access tooling rather than a Buildbarn detail. It grew a `hint`
  argument so each caller prints its own closing line.
- **Alertmanager's null route is the chart default**, so no config block was
  needed to stub delivery — only the note saying it is deliberate.
- The worker node's real commitment is 6100m of 7950m CPU and 1980Mi of memory
  *requests* against 34304Mi of limits (111% overcommit). The M7 table was close
  enough; the alert now watches the ratio directly.

### Deploying it

Flux tracks `main`, so nothing above is running yet. Merging is what deploys it,
and the order matters once: **M2's machine-config change should be applied
before or alongside the merge**, or the control-plane and etcd scrape jobs come
up as three permanently-down targets on day one — the exact thing M2 exists to
prevent.

```
bazel run //infra/talos:genconfig
talosctl apply-config --nodes <cp>  ...   # one at a time
```

Then work the remaining gates in order: M1 (`up == 1`), M2 (zero down targets),
M3 (one query per signal, recorded), M4 (kill a worker, find its last lines),
M5 (scale `storage` to zero, watch `BuildbarnComponentDown` fire and resolve).
