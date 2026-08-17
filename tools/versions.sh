#!/usr/bin/env bash
# Prints the pinned version of every CLI tool in //tools:tools.bzl.
#
# Proof that every tool the infrastructure depends on resolves through Bazel at
# a pinned version, on a clean machine.
#
# Each argument is "name:versionargs:rlocationpath", where versionargs is
# comma-separated. //tools:BUILD.bazel generates these from TOOLS.

# --- begin runfiles.bash initialization v3 ---
set -uo pipefail
set +e
f=bazel_tools/tools/bash/runfiles/runfiles.bash
source "${RUNFILES_DIR:-/dev/null}/$f" 2>/dev/null ||
  source "$(grep -sm1 "^$f " "${RUNFILES_MANIFEST_FILE:-/dev/null}" | cut -f2- -d' ')" 2>/dev/null ||
  source "$0.runfiles/$f" 2>/dev/null ||
  source "$(grep -sm1 "^$f " "$0.runfiles_manifest" | cut -f2- -d' ')" 2>/dev/null ||
  {
    echo >&2 "ERROR: cannot find $f"
    exit 1
  }
f=
set -e
# --- end runfiles.bash initialization v3 ---

status=0

for spec in "$@"; do
  name="${spec%%:*}"
  rest="${spec#*:}"
  version_args="${rest%%:*}"
  rlocation_path="${rest#*:}"

  binary="$(rlocation "$rlocation_path")"
  if [[ -z "$binary" || ! -x "$binary" ]]; then
    printf '%-20s %s\n' "$name" "MISSING ($rlocation_path)"
    status=1
    continue
  fi

  if [[ -z "$version_args" ]]; then
    printf '%-20s %s\n' "$name" "(no version flag; pinned in multitool.lock.json)"
    continue
  fi

  IFS=',' read -r -a args <<<"$version_args"

  # Tools disagree on whether version output goes to stdout or stderr, and
  # several wrap it in banners ("Client:", build metadata, update notices).
  # The one thing they agree on is printing a semver, so report the first line
  # that contains one.
  if ! output="$("$binary" "${args[@]}" 2>&1)"; then
    printf '%-20s %s\n' "$name" "FAILED: ${output%%$'\n'*}"
    status=1
    continue
  fi

  if ! line="$(grep -m1 -E 'v?[0-9]+\.[0-9]+\.[0-9]+' <<<"$output")"; then
    printf '%-20s %s\n' "$name" "NO VERSION IN OUTPUT: ${output%%$'\n'*}"
    status=1
    continue
  fi

  # Trim leading/trailing whitespace ("\tTag: v1.13.8").
  line="${line#"${line%%[![:space:]]*}"}"
  printf '%-20s %s\n' "$name" "${line%"${line##*[![:space:]]}"}"
done

exit "$status"
