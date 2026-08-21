#!/usr/bin/env bash
# Opens the ports a developer needs against one of the clusters, and holds them
# until interrupted.
#
# Lives here rather than in buildbarn/ because two packages now use it -- the
# cache tunnels and the monitoring one. It is cluster access tooling, not a
# Buildbarn detail, and one copy is the only way the two stay in step about
# which kubeconfig belongs to which cluster.
#
# Usage (from //infra/platform/buildbarn:tunnel-local | :tunnel-hetzner, or
# //infra/platform/monitoring:tunnel-hetzner):
#   tunnel.sh <kubectl-rlocationpath> <context-or-kubeconfig> <label> <spec...>
#
# Each spec is "namespace/service:localport:remoteport".
#
# TUNNEL_HINT is the one line printed once the tunnels are up, and differs by
# what they are for: a cache tunnel wants a --config to build with, a dashboard
# tunnel wants a URL. It arrives through the environment rather than as an
# argument because Bazel applies Bourne tokenization to `args`, so a value with
# a space in it silently becomes several arguments -- which this script then
# reads as port specs, and reports as "a port-forward exited immediately".

# --- begin runfiles.bash initialization v3 ---
set -uo pipefail
set +e
f=bazel_tools/tools/bash/runfiles/runfiles.bash
source "${RUNFILES_DIR:-/dev/null}/$f" 2>/dev/null ||
  source "$(grep -sm1 "^$f " "${RUNFILES_MANIFEST_FILE:-/dev/null}" | cut -f2- -d' ')" 2>/dev/null ||
  source "$0.runfiles/$f" 2>/dev/null ||
  source "$(grep -sm1 "^$f " "$0.runfiles_manifest" | cut -f2- -d' ')" 2>/dev/null ||
  { echo >&2 "ERROR: cannot find $f"; exit 1; }
f=
set -e
# --- end runfiles.bash initialization v3 ---

set -euo pipefail

kubectl="$(rlocation "$1")"
target="$2"
label="$3"
hint="${TUNNEL_HINT:-}"
shift 3

if [[ -z "${BUILD_WORKSPACE_DIRECTORY:-}" ]]; then
  echo >&2 "ERROR: use 'bazel run' -- the Hetzner kubeconfig is read from the source tree."
  exit 1
fi

# The two clusters are reached differently: the local one is a context in the
# usual kubeconfig, the Hetzner one has a kubeconfig of its own -- committed,
# and holding no credential, because it reaches the cluster through the
# Tailscale operator's API server proxy. Passing the wrong one is the single
# easiest way to build against the cluster you did not mean, so it is decided
# here rather than by whatever KUBECONFIG happens to be exported.
#
# Port-forwarding is what makes the cache reachable rather than exposing the
# frontends on the tailnet directly, and that is a constraint rather than a
# preference: a Tailscale layer-4 proxy DNATs to a ClusterIP, and Cilium's
# kube-proxy replacement does not translate services for traffic *forwarded
# through* a pod. The packets leave the node masqueraded, still addressed to the
# ClusterIP, and are routed to the internet where that address means nothing --
# a timeout with no drop event anywhere. Grafana escapes this because an Ingress
# proxy terminates the connection and opens its own socket, which does get
# translated. gRPC cannot use that path: the Ingress proxies HTTP/1.1 upstream.
if [[ "$target" == /* || "$target" == *.yaml || "$target" == */* ]]; then
  export KUBECONFIG="${BUILD_WORKSPACE_DIRECTORY}/${target#/}"
  unset_ctx=1
else
  unset KUBECONFIG
  "$kubectl" config use-context "$target" >/dev/null
  unset_ctx=0
fi

pids=()
cleanup() {
  echo >&2
  echo >&2 "Closing tunnels."
  for p in "${pids[@]:-}"; do kill "$p" 2>/dev/null || true; done
}
trap cleanup EXIT INT TERM

echo >&2 "Tunnelling to ${label}:"
for spec in "$@"; do
  ns="${spec%%/*}"; rest="${spec#*/}"
  svc="${rest%%:*}"; ports="${rest#*:}"
  "$kubectl" -n "$ns" port-forward "svc/${svc}" "$ports" >/dev/null 2>&1 &
  pids+=($!)
  echo >&2 "  ${svc}  localhost:${ports%%:*}"
done

sleep 2
for p in "${pids[@]}"; do
  if ! kill -0 "$p" 2>/dev/null; then
    echo >&2 "ERROR: a port-forward exited immediately. Is the cluster up?"
    exit 1
  fi
done

echo >&2
echo >&2 "Ready. ${hint} Ctrl-C to close."
wait
