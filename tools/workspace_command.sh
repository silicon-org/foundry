#!/usr/bin/env bash
# Runs a Bazel-pinned CLI against a directory in the source tree.
#
# Usage (from //tools:workspace_command.bzl):
#   workspace_command.sh <rlocationpath> <workdir> <args...>
#
# Arguments passed after `--` on the `bazel run` command line are appended.

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

tool="$(rlocation "$1")"
workdir="$2"
shift 2

if [[ -z "${BUILD_WORKSPACE_DIRECTORY:-}" ]]; then
  echo >&2 "ERROR: use 'bazel run', not 'bazel build' -- this needs the source tree."
  exit 1
fi

cd "${BUILD_WORKSPACE_DIRECTORY}/${workdir}"
exec "$tool" "$@"
