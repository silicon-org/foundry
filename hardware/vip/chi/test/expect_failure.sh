#!/usr/bin/env bash
# Runs a testbench, requires it to fail, and requires it to fail for the stated
# reason.
#
# A check nobody has watched fire is decoration, so every invariant in the link
# layer has a case that violates it deliberately. Two things have to be true for
# such a case to mean anything: the run must fail, and it must fail because the
# intended check tripped rather than because something else fell over first.
# Hence the expected text -- without it, a testbench that crashed on an
# unrelated bug would look like a passing negative test.
#
#   expect_failure.sh <binary> <expected-substring> [args...]
set -uo pipefail

binary="$1"
expected="$2"
shift 2

output="$("$binary" "$@" 2>&1)"
status=$?

if [[ $status -eq 0 ]]; then
  echo "$output"
  echo
  echo "expect_failure: $(basename "$binary") $* passed, and it was supposed to fail."
  echo "The check it was meant to trip either is not there or does not fire."
  exit 1
fi

if ! grep -qF -- "$expected" <<<"$output"; then
  echo "$output"
  echo
  echo "expect_failure: $(basename "$binary") $* failed, but not for the stated reason."
  echo "Expected to find: $expected"
  exit 1
fi

echo "expect_failure: failed as intended (status $status), on:"
grep -F -- "$expected" <<<"$output" | head -3
exit 0
