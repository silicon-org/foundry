#!/usr/bin/env bash
# Runs the Bazel-pinned tofu against a module in the source tree.
#
# Usage (from //infra/tofu:tofu.bzl): tofu_wrapper.sh <rlocationpath> <module> <args...>
# Extra arguments passed after `--` on the bazel run command line are appended.

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

set -euo pipefail

tofu="$(rlocation "$1")"
module="$2"
shift 2

if [[ -z "${BUILD_WORKSPACE_DIRECTORY:-}" ]]; then
  echo >&2 "ERROR: use 'bazel run', not 'bazel test' -- tofu needs the source tree."
  exit 1
fi

cd "${BUILD_WORKSPACE_DIRECTORY}/${module}"
exec "$tofu" "$@"
