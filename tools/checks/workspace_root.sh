#!/usr/bin/env bash
# Finds the source tree from inside a test, and cds there.
#
# Sourced by the checks in this directory, which all inspect files rather than
# build outputs: `ruff check` wants the whole package, and the size check wants
# what git tracks. Neither is a list of srcs, and a list only ever holds what
# somebody remembered to add -- the same reasoning //tools/format:format_test
# gives for the same trade.
#
# The caller must pass the rlocationpath of a file at the workspace root as $1.
# In the runfiles tree that entry is a symlink *to* the source file, so the link
# has to be resolved before taking its directory -- `pwd -P` on the runfiles
# directory only ever yields the runfiles directory.

# Follows a chain of symlinks by hand. `readlink -f` would do it, but the BSD
# readlink on older macOS has no -f, and this is three lines.
_resolve_symlink() {
  local path="$1" target
  while [[ -L "${path}" ]]; do
    target="$(readlink "${path}")"
    [[ "${target}" == /* ]] || target="$(dirname "${path}")/${target}"
    path="${target}"
  done
  printf '%s' "${path}"
}

marker="$(rlocation "$1")"
if [[ -z "${marker}" || ! -e "${marker}" ]]; then
  echo >&2 "ERROR: cannot find the workspace marker '$1' in runfiles."
  exit 1
fi

WORKSPACE_ROOT="$(cd "$(dirname "$(_resolve_symlink "${marker}")")" && pwd -P)"
readonly WORKSPACE_ROOT

# -e rather than -d: in a git worktree .git is a *file* holding a gitdir pointer,
# and this repository is developed in worktrees.
if [[ ! -e "${WORKSPACE_ROOT}/.git" ]]; then
  echo >&2 "ERROR: ${WORKSPACE_ROOT} is not the source tree -- the marker did not"
  echo >&2 "       resolve out of the execroot. Is the test still sandboxed?"
  exit 1
fi

cd "${WORKSPACE_ROOT}"
