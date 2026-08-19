#!/usr/bin/env bash
# Checks every PrometheusRule in the tree with promtool, at commit time.
#
# The Prometheus operator does validate these -- through an admission webhook,
# minutes after the push, with the error in a controller log attached to
# nothing. Same argument as kustomize_test.sh: a broken expression should fail
# the change that broke it.
#
# Usage: promtool_test.sh <promtool-rlocationpath> <rule-file...>

set -euo pipefail

promtool="${TEST_SRCDIR}/$1"
shift

work="${TEST_TMPDIR}/rules"
mkdir -p "$work"

status=0
for rule in "$@"; do
  src="${TEST_SRCDIR}/${TEST_WORKSPACE}/${rule}"

  if ! grep -q '^kind: PrometheusRule$' "$src"; then
    printf 'FAIL  %-45s not a PrometheusRule\n' "$rule"
    status=1
    continue
  fi

  # promtool wants a bare rules file: `groups:` at the top level. A
  # PrometheusRule wraps exactly that in `spec:`, so unwrap it -- everything
  # after the `spec:` line, dedented by the two spaces it is nested under.
  #
  # Deliberately not a YAML parser. There is no yq in //tools and adding one to
  # unwrap a single key would be a dependency bigger than the thing it does. If
  # the shape ever changes, promtool says so immediately rather than passing
  # something wrong.
  out="${work}/$(echo "$rule" | tr / _)"
  awk '/^spec:$/ {found=1; next} found {sub(/^  /, ""); print}' "$src" > "$out"

  if ! grep -q '^groups:' "$out"; then
    printf 'FAIL  %-45s no groups: found under spec:\n' "$rule"
    status=1
    continue
  fi

  if result="$("$promtool" check rules "$out" 2>&1)"; then
    printf 'ok    %-45s %s rules\n' "$rule" "$(grep -cE '^\s+- (alert|record):' "$src")"
  else
    printf 'FAIL  %s\n%s\n' "$rule" "$result"
    status=1
  fi
done
exit "$status"
