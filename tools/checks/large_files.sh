#!/usr/bin/env bash
# Refuses tracked files above a size limit.
#
#   large_files.sh <workspace-marker-rlocationpath> <limit-bytes>
#
# This repository's whole third-party strategy is that sources are fetched and
# pinned rather than vendored, so a large file arriving in the history is
# usually a mistake -- a build output, a captured waveform, a tarball someone
# meant to add to //MODULE.bazel. Git keeps it forever either way, which is why
# this is a check and not a cleanup.
#
# The escape hatch is `large-file-ok` in .gitattributes, next to whatever needs
# it, so that an exception is a decision someone wrote down.

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

source "$(rlocation _main/tools/checks/workspace_root.sh)" "$1"
limit="$2"

# Only what git tracks: an untracked build output in someone's working tree is
# not this check's business and never enters the history.
#
# A read loop rather than `mapfile -d`, which needs bash 4 -- macOS ships 3.2.
files=()
while IFS= read -r -d '' file; do
  files+=("${file}")
done < <(git ls-files -z)

allowed() {
  [[ "$(git check-attr large-file-ok -- "$1" | sed 's/.*: //')" == "set" ]]
}

oversized=()
for file in "${files[@]}"; do
  [[ -f "${file}" ]] || continue
  size=$(wc -c <"${file}")
  if ((size > limit)) && ! allowed "${file}"; then
    oversized+=("$(printf '%10d  %s' "${size}" "${file}")")
  fi
done

if ((${#oversized[@]} > 0)); then
  echo >&2 "Tracked files above ${limit} bytes:"
  printf '%s\n' "${oversized[@]}" >&2
  echo >&2
  echo >&2 "Fetch it in //MODULE.bazel and pin it by hash, or generate it in the"
  echo >&2 "build. If it genuinely belongs in git, say so in .gitattributes:"
  echo >&2
  echo >&2 "    path/to/file large-file-ok"
  exit 1
fi
