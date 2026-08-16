# Monitoring

kube-prometheus-stack (Prometheus, Grafana, Alertmanager) plus Loki for logs.
Exposed to the tailnet only.

Signals that matter here, beyond the usual cluster health:

- **Buildbarn**: cache hit rate, action queue depth, worker saturation. This is
  the number that says whether remote execution is actually paying for itself.
- **Cilium/Hubble**: flow metrics, and specifically *dropped* flows from
  `arc-runners`. A default-deny policy that never drops anything usually means
  it isn't applied.
- **ARC**: runner pod lifecycle, queue wait time.

## One external check, off-cluster

Self-hosted monitoring cannot page you when the box itself is down. Exactly one
uptime check lives outside this cluster, run by something we don't operate. It
is deliberately dumb — reachability, not detail.
