#!/usr/bin/env bash
# Renders every kustomize root and fails if any of them is broken.
#
# Without this, a malformed kustomization reaches the cluster and shows up as a
# Flux reconcile failure -- somewhere nobody is looking, minutes after the push,
# with the error attached to a controller rather than to the commit.

set -euo pipefail

# rlocationpath is relative to the runfiles root, which is TEST_SRCDIR --
# not the workspace directory inside it.
kubectl="${TEST_SRCDIR}/$1"
shift

# kustomize will not follow a symlinked kustomization.yaml, and every file in
# Bazel's runfiles is a symlink. Copy with -L to dereference them first.
work="${TEST_TMPDIR}/src"
mkdir -p "$work"
cp -RL "${TEST_SRCDIR}/${TEST_WORKSPACE}/infra" "$work/"
cd "$work"

status=0
for root in "$@"; do
  if out="$("$kubectl" kustomize "$root" 2>&1)"; then
    printf 'ok    %-45s %s objects\n' "$root" "$(grep -c '^kind:' <<<"$out")"
  else
    printf 'FAIL  %s\n%s\n' "$root" "$out"
    status=1
  fi
done
exit "$status"
