#!/usr/bin/env bash
# Refuses a SystemVerilog comment line that begins with the simulator's name.
#
#   verilog_comments.sh <workspace-marker-rlocationpath>
#
# A `//` comment whose first word is that name is a *pragma*, not prose, and the
# build fails with %Error-BADVLTPRAGMA quoting a sentence back at you. The trap
# is not writing one deliberately -- nobody does -- it is reflowing a paragraph
# so that a line happens to start with the word. It has been sprung three times
# in this repository, twice after the lesson was written down, which is the
# definition of something a person should stop being asked to remember.
#
# The rule is narrow on purpose: only a comment whose first token is the name,
# which is exactly what the parser treats as a pragma. Saying it anywhere else
# in a sentence is fine and common.

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

# The real pragmas are the ones with a directive after the name -- those are
# deliberate and legal. What is refused is prose.
pattern='^[[:space:]]*//[[:space:]]*[Vv]erilator[[:space:]]'
allowed='//[[:space:]]*verilator[[:space:]]+(lint_off|lint_on|lint_save|lint_restore|tracing_off|tracing_on|public|public_flat|public_flat_rd|public_flat_rw|no_inline_module|no_inline_task|isolate_assignments|split_var|coverage_off|coverage_on|sc_bv|systemc_clock|clocker|no_clocker|hier_block|timing_on|timing_off)'

found=0
while IFS= read -r -d '' file; do
  # `git grep -n` would be faster, but this has to see files that are staged and
  # not yet committed, which is what the git hook needs.
  while IFS= read -r hit; do
    line=${hit#*:}
    if [[ ! "$line" =~ $allowed ]]; then
      if ((found == 0)); then
        echo >&2 "A comment line starting with the simulator's name is parsed as a pragma:"
        echo >&2
      fi
      found=1
      echo >&2 "  ${file}:${hit%%:*}: ${line}"
    fi
  done < <(grep -nE "$pattern" "$file" 2>/dev/null || true)
  # Untracked files too, not just tracked ones: this rule is about whether the
  # tree *builds*, and the build reads a file whether or not git knows it. The
  # size check next door is tracked-only on purpose -- what is not tracked never
  # enters the history, which is what that one is about.
done < <(git ls-files -z --cached --others --exclude-standard '*.sv' '*.svh' '*.v' '*.vh')

if ((found != 0)); then
  echo >&2
  echo >&2 "Reword so the line does not begin with it -- 'The simulator supports...'"
  echo >&2 "or move the word further into the sentence."
  exit 1
fi
