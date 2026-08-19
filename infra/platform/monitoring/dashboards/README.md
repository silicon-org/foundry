# Dashboards

Committed as JSON, provisioned by the Grafana sidecar from the ConfigMaps that
`../kustomization.yaml` generates. Grafana runs with `persistence.enabled:
false`, so a dashboard edited in the UI survives until the pod restarts and no
longer.

That is the feature. A dashboard nobody can review, diff or rebuild is a
dashboard that quietly stops matching the metrics it draws.

## Editing one

Edit it in Grafana, then **Dashboard settings → JSON Model**, copy, and replace
the file here. Keep the `uid` unchanged -- it is what links a dashboard to its
URL and to any link pointing at it.

## Where each came from

| File | Origin |
|---|---|
| `buildbarn.json` | Written here. Nobody publishes one, and the metric surface is not what a general dashboard would assume -- see `../rules/buildbarn.yaml`. |
| `arc.json` | Written here, for the same reason. |
| `cilium-agent.json`, `cilium-operator.json`, `hubble.json` | `cilium/cilium` at `v1.20.0`, under `install/kubernetes/cilium/files/*/dashboards/`. The same tag as the chart in `../../cilium`. |
| `flux-cluster.json`, `flux-control-plane.json` | `fluxcd/flux2-monitoring-example`, `monitoring/configs/dashboards/`. |

Node, Kubernetes and Prometheus dashboards are not here: kube-prometheus-stack
ships them with the chart, and vendoring a second copy would mean maintaining
one.

Vendored rather than referenced by `gnetId`. A dashboard fetched at render time
is an unpinned dependency with a network call in front of it -- and
`../networkpolicy.yaml` denies Grafana the internet, so it would not resolve
anyway.

## One size caveat

`cilium-agent.json` is 280KB, which is past the 262144-byte limit on the
`last-applied-configuration` annotation that a *client-side* `kubectl apply`
writes. Flux applies server-side and sets no such annotation, so it deploys
fine; a human running `kubectl apply -f` against it needs `--server-side`.

Each vendored dashboard therefore gets its own ConfigMap, so that limit stays a
property of one known-large file rather than something the next dashboard added
here quietly trips over.
