#!/usr/bin/env bash
# Opens the ports a developer needs against one of the clusters, and holds them
# until interrupted.
#
# Usage (from //infra/platform/buildbarn:tunnel-local | :tunnel-hetzner):
#   tunnel.sh <kubectl-rlocationpath> <context-or-kubeconfig> <label> <spec...>
#
# Each spec is "namespace/service:localport:remoteport".

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
shift 3

if [[ -z "${BUILD_WORKSPACE_DIRECTORY:-}" ]]; then
  echo >&2 "ERROR: use 'bazel run' -- the Hetzner kubeconfig is read from the source tree."
  exit 1
fi

# The two clusters are reached differently: the local one is a context in the
# usual kubeconfig, the Hetzner one has a kubeconfig of its own that talhelper
# wrote. Passing the wrong one is the single easiest way to build against the
# cluster you did not mean, so it is decided here rather than by whatever
# KUBECONFIG happens to be exported.
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
echo >&2 "Ready. Build with --config=${label}-dev. Ctrl-C to close."
wait
