#!/usr/bin/env bash
# Lints the Python with the pinned ruff.
#
#   ruff_check.sh <workspace-marker-rlocationpath> <ruff-rlocationpath>
#
# The other half of //tools/format, which runs `ruff format`. Formatting settles
# how the code looks; this is what notices an unused import, a name that does not
# exist, or a mutable default argument. Configured in //:pyproject.toml.

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

ruff="$(rlocation "$2")"
source "$(rlocation _main/tools/checks/workspace_root.sh)" "$1"

# --no-cache because the cache would land in the source tree, and a test that
# writes to the workspace is a test that behaves differently the second time.
exec "${ruff}" check --no-cache .
