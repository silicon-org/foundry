# Clean-up: a formatter the build owns

Two things were wrong, and one of them is now fixed:

1. **Nothing formatted the C++ or the Starlark.** Fixed — see Part A.
2. **CHIron is vendored** behind a `refresh.sh` that tracks upstream. Decided,
   deferred — see Part B.

## Part A — One formatter, run by Bazel  ✅

`aspect_rules_lint`'s `format_multirun`, wired to the toolchain we already have.
Not the pre-commit framework: it would be a second tool-pinning mechanism next
to multitool and Bazel, managing its own hook environments, which is the job
those two already do. The hook is ten lines of shell instead, and needs no
Python and no uv.

Two things made it nearly free:

- **clang-format was already on disk.** `@llvm//tools:clang-format` resolves
  into the prebuilt seed `hermetic-llvm` downloads before it can compile
  anything — a multicall symlink into the single `llvm` binary, present for all
  four platforms. So the formatter is the same LLVM that compiles the code, and
  it moves when the compiler moves.
- **buildifier is a multitool pin.** `bazelbuild/buildtools` v8.5.1 publishes
  bare per-platform binaries on GitHub releases, the exact shape
  `//tools:update` already bumps. One lockfile entry, one line in `tools.bzl`,
  and it is on `PATH` and in `//tools:versions` with no further wiring.

### What landed

- [x] `bazel_dep(name = "aspect_rules_lint", version = "2.8.0", dev_dependency = True)`
- [x] `buildifier` in `multitool.lock.json` (four platforms, v8.5.1) and in
      `TOOLS`
- [x] `//tools/format`, with the tool labels in one dict in `defs.bzl` so the
      runner and the test cannot drift. A BUILD file may not pass `**kwargs`,
      which is why the dict is not in `BUILD.bazel`.
- [x] `format` in the `bazel_env` tools dict, so it is on `PATH`
- [x] `.clang-format` at the root
- [x] `tools/githooks/pre-commit`, installed by `.envrc` pointing `core.hooksPath` at
      it — so `direnv allow` remains the only setup step
- [x] `//tools/README.md` documents all of it
- [x] **CI needs no new step.** `format_test` is a test, and the `Everything`
      step already runs `bazel test //...`.

### Two things found on the way, both worth knowing

**`*.BUILD.bazel` overlays were invisible to the formatter.** rules_lint selects
a language's files with GitHub Linguist's patterns, and Linguist knows
`BUILD.bazel` but not `xiangshan.BUILD.bazel` — which is the name every BUILD
file in this repository takes when it describes a third-party archive. Ten of
our fifteen unformatted Starlark files were in that blind spot, and a check that
skips a whole file class silently is worse than no check at all. Patched in
`//tools/format:patches/`, one line, applied through `single_version_override`.
The list already carries `*.MODULE.bazel`, so this is that precedent applied to
the other half of the convention. Worth sending upstream.

**rules_multitool had to stop being a dev dependency.** rules_lint declares hubs
on the same extension and does so non-dev; rules_multitool sorts every module's
hub tag into one of two lists it hands Bazel, and ours being dev while theirs
was not put the default hub in both. Bazel rejects that outright. Marking ours
non-dev is the smaller lie — this module is a leaf that nothing depends on.

### The `.clang-format`, chosen by measurement

The code was already Google-shaped, so the only real questions were the column
limit and one habit:

| config | lines changed |
|---|---|
| Google (80 columns) | 479 |
| Google, 100 columns | 238 |
| Google, 100 columns, short case labels | **195** |
| Google, 110 columns, short case labels | 235 |

Measured against the C++ on `xs-cluster-tb`, which is where nearly all of it
lives; `main` has one C++ file. 100 is where the code already sits — the longest
line in the tree is 106 and three files exceed 100. Hand-wrapped 80-column
comment prose is unaffected: clang-format breaks a comment that is too long, it
never joins ones that are short.

### What the reformat actually did

15 Starlark files and 1 C++ file on this branch. The C++ was two joined
`printf` calls. The Starlark was mostly buildifier's canonical ordering of rule
attributes — `sha256` after `patch_cmds`, and so on — which moves each
attribute's comment with it, so nothing came detached. `MODULE.bazel` also had
its multi-argument extension tag calls expanded one argument per line, which is
what buildifier does to a file it recognises as a module file.

Kept in its own commit, so `git blame` can be told to skip it.

### Gates, all passed

- `bazel test //tools/format:format_test` — red before, green after, and it
  names the files and the fix command when it fails.
- `bazel run //tools:versions` reports buildifier 8.5.1 alongside the rest.
- The hook was run against a deliberately misformatted staged file: it
  reformatted it, refused the commit, and said how to proceed.
- `bazel build --nobuild //...` analyses all 62 targets, so the reformatting of
  `circt.BUILD.bazel` (294 lines) changed no meaning.
- `//infra/platform:kustomize_test`, `:promtool_test` and the reformatted
  `//hardware/ip/common_cells/test:lzc_test` all pass.

## Part B — CHIron: adopt it, do not track it

**Decided, deliberately not done yet.** The `http_archive` route this document
first argued for is off the table: the plan is to take the files in, format them
as ours, change them as needed, and drop the relationship with upstream
entirely.

That answers the objection this whole section started from. The problem with the
current arrangement was never the copy — it was the copy *pretending to be a
reference*: `refresh.sh`, a hand-derived list of 17 filenames, patches applied
on top, and a `PROVENANCE.md` explaining how to re-derive it all. That is the
cost of a fork with none of the benefits of a pin. If the code is ours, the
machinery that keeps it comparable to upstream is dead weight, the layout is
ours to choose, and the patches stop being patches and become edits.

What has to happen, when it happens:

- `refresh.sh`, `patches/`, and the reference half of `PROVENANCE.md` go away;
  what survives is a short note saying where the code came from, that it is
  Apache-2.0, and that `LICENSE` is upstream's — the licence obligation outlives
  the relationship.
- The two fixes stop being patch files and become the code. They should still be
  sent upstream first: both are real bugs in `Serialize*` and in the two address
  readers, and sending them costs nothing once they are written.
- The tree gets a layout we choose, and gets formatted by `//tools/format` like
  everything else — no exclusion needed, because by then it is our code. Worth
  measuring the clang-format diff on 15k lines of someone else's style before
  committing to it; it will be large and it will only ever be paid once.

Not scheduled here because there is more CHIron work in flight on
`xs-cluster-tb` (PR #4), and the shape of what we keep is not settled until that
lands.

## Part C — uv, and why there is nothing for it to do yet

Researched, and the honest answer is that this repository has no Python. The
formatters are three native binaries, all pinned by mechanisms we already run.
Adopting `rules_uv` or `rules_python`'s `//python/uv` today would be machinery
with nothing to lock and no venv to make. Both are healthy and worth reaching
for the moment real Python lands; neither is worth reaching for before that.

There is exactly one place a hermetic Python would earn its keep today, and it
is not a formatter: **`//MODULE.bazel` shells out to the host's `python3`** in
CIRCT's `patch_cmds`. Repository rules run outside the toolchain and outside
`--incompatible_strict_action_env`, so that heredoc is the one piece of this
build that resolves an interpreter from `PATH` — on a laptop, and on a runner
image that "deliberately ships almost nothing". It works today because both
happen to have one. Worth its own change; uv is a plausible answer when it comes.

## Deliberately not in scope

- **SystemVerilog.** verible publishes linux arm64/x86_64 and macOS binaries so
  it is pinnable, but rules_lint has no `verilog` attribute — it would need its
  own target or a second upstream contribution — and verible is opinionated
  enough to churn hand-laid RTL. Its own change, with its own before-and-after
  read.
- **YAML and Markdown.** The largest diff of the three, mostly in Flux manifests
  where it is noise, and prettier would reflow prose that is hand-wrapped at 80.
- **Shell.** shfmt is a small add and a small diff; left out only to keep this
  change to what was asked. Cheap to fold in later.
- **`buildifier --lint=warn`.** Format mode is clean; lint mode reports 11
  `duplicated-name` warnings in `third_party/circt/circt.BUILD.bazel`, all false
  positives from the `circt_dialect` macro, which buildifier cannot see through.
  Turning lint on means suppressing those first.
