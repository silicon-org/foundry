# Lessons

Patterns worth not relearning. Added after a correction, or after something cost
more time than it should have.

## Build

- The Bazel build of llvm-project is in LLVM's *peripheral* support tier —
  "experimental and best-effort" in their own README, and reviewers do not
  require contributors to keep it working. Treat a green upstream Buildkite as
  luck rather than a guarantee, and pin rather than track.

- `--platforms` does not change the output directory name. All three platforms
  land in `bazel-out/darwin_arm64-fastbuild/`, so switching between them
  overwrites the previous platform's artifacts and replays ~600 actions from the
  action cache. Consequence when checking a cross-compile: `file` on the artifact
  tells you about the *last* build, not the one you think you are looking at.
  Rebuild the platform you want immediately before inspecting it.
  `--experimental_platform_in_output_dir` is the fix; it is a repo-wide change
  that invalidates local output trees, so it is a decision rather than a tidy-up.

- The firtool closure is much smaller than CIRCT: 33 libraries over 11 dialects
  and roughly 230 C++ files, against 645 under `lib/` for the whole project.
  Only three tablegen rules in the whole closure need the custom `circt-tblgen`
  binary, and one of them lives in `lib/Dialect/FIRRTL/CMakeLists.txt` rather
  than under `include/`, which is easy to miss when surveying only `include/`.

- The `-fno-rtti` / `-fno-exceptions` that CIRCT and LLVM are famous for is a
  CMake artifact, not a property of the code. `HandleLLVMOptions.cmake` injects
  it when `LLVM_ENABLE_RTTI=OFF`; the Bazel overlay sets no such flag anywhere --
  `llvm_copts` is `["$(STACK_FRAME_UNLIMITED)"]` and nothing else -- so LLVM and
  MLIR compile here with whatever the toolchain defaults to, which is RTTI and
  exceptions on. Build CIRCT the same way and slang's requirements stop
  conflicting.

  This does *not* retract the ABI argument for plugins against a **released**
  firtool: that binary really is built `-fno-rtti` against libstdc++, and a
  plugin must still match it. The two statements are about different binaries.

- `gentbl_cc_library`'s `deps` are TableGen dependencies, not C++ ones, and the
  generated `.inc` files land in `textual_hdrs`. A consumer therefore depends on
  both the IncGen target and the real C++ libraries, separately -- which is why
  every MLIR `cc_library` lists `":FooIncGen"` alongside `":IR"`. Its `**kwargs`
  reach four different rules including a `filegroup`, so only universally
  accepted attributes (`visibility`, `tags`, `testonly`) may be passed through.

- CIRCT's `circt/Conversion/Passes.h` is a hard umbrella: it includes every
  conversion, each of which includes its dialect's headers and their generated
  .inc files. Including it needs tablegen for all thirty-two dialects even
  though firtool links thirteen libraries. Narrowing it means narrowing
  `Passes.td` in the same patch, because the generated registration block calls
  `createX()` for every def in the table -- and the keep set has to come from
  the `GEN_PASS_DEF_*` each library defines, not from what the headers declare.
  ExportVerilog implements three passes its own header never mentions.

- Removing includes removes what they dragged in behind them. Firtool.cpp uses
  `llvm::ManagedStatic` and firtool.cpp uses `llvm::sys::SmartMutex` without
  including either; both only ever compiled because a conversion header up the
  chain included them.

- A C++ target's module map is named after the target, so on macOS a
  `cc_library` and a `cc_binary` whose names differ only in case collide in the
  sandbox: "Could not copy inputs into sandbox: firtool.cppmap (File exists)".
  CMake's CIRCTFirtool/firtool pair is exactly that. Same hazard as the YunSuan
  patch in //MODULE.bazel.

- XiangShan's Chisel elaboration is **not reproducible**. Two runs of the same
  generator, same config, same everything, produce different FIRRTL: 288 lines,
  every one a `brAttribute_WIRE_N` temporary whose suffix shifts. firtool then
  passes those names through faithfully, so the emitted SystemVerilog differs
  too. This predates building CIRCT from source -- the prebuilt binary has the
  same behaviour, because the variation is upstream of it.

  **Found and fixed.** `utils/EnumUInt.scala` discovers an enum's members with
  `Class.getDeclaredMethods`, which the JDK documents as returning them "not
  sorted and ... not in any particular order", and which does vary run to run.
  `validate()` keeps that order and `assertLegal` emits one comparison per value
  in it, so a reordering renames FIRRTL nodes and changes every byte downstream.
  Sorting by name in //MODULE.bazel's patch_cmds fixes it. Worth sending
  upstream: the same file already sorts for its own error messages ten lines
  earlier, so the order was never meant to be meaningful.

- When comparing two compilers, compare them on *one* input. Running the whole
  pipeline twice and diffing the ends conflates every stage; dumping the
  intermediate and feeding it to both binaries took the question from "216 names
  differ, why?" to a byte-identical hash in one step.

- Four hypotheses died before the right one. Worth keeping the order, because
  each test was cheap and each ruled out a whole class:

  | hypothesis | test | outcome |
  |---|---|---|
  | firtool differs from the release binary | both binaries, one 518 MB input | identical |
  | espresso is nondeterministic | 60 captured inputs, replayed | deterministic |
  | JVM identity-hash iteration order | `-XX:hashCode=3`, then `=2` | still varied |
  | CIRCT's FIRRTL parse/print | `--dump-fir` to split the pipeline | raw .fir varied too |

  `-XX:hashCode=2` is the airtight form of the hash test -- it returns a constant
  for every object, so no iteration over an identity-keyed map can vary.
  `hashCode=3` is a global counter and only looks deterministic: any other
  thread calling hashCode advances it.

- The generator needs NOOP_HOME set, or it throws NoSuchElementException from
  difftest *after* writing its output. Running it by hand outside the Bazel rule
  therefore produces complete artifacts and a non-zero exit, which is a good way
  to believe a build failed when it did not, or to miss that it did.

## Verification

- CHIron's flit serializer has never worked. `FlitAppender::Append32` omits the
  `else` that advances `offset`, so every field that does not cross a word
  boundary is written on top of the previous one; the crossing path advances
  `index` twice; and the mask shifts by 32 when a field ends on a boundary. The
  function's own `Finish()` assertion catches it on the first flit, which is
  how you find out. `Deserialize*` is fine -- it came in the one human-authored
  pull request the repository has merged, and the rest is unexercised. Assume
  the same of anything else there until a test says otherwise.

- Two of CHIron's twelve multi-word reads drop the `<< 32` on the high half, so
  a REQ or SNP address decodes with its top bits OR-ed over its bottom ones.
  General lesson: when the same idiom appears a dozen times and two of them
  differ, the two are wrong, and routing all twelve through one helper is worth
  more than fixing the two.

- A round-trip test is weak on its own -- a packer and an unpacker wrong in the
  same way agree with each other. Pin the bit positions first, from an
  independent table, by setting one field to all ones and requiring exactly
  that range to come out set. Both CHIron bugs above survived a round trip
  during development and died to the position sweep.

- The `--timing` flag is what lets the clock live in SystemVerilog, and
  rules_verilator responds to it by compiling the generated model at
  `-std=c++20` whatever the rest of the build uses. Two halves of one binary at
  two standards is not a configuration worth having, so `--timing` effectively
  decides the repository's C++ standard.

- CHIron's headers are CRLF. Rewriting one with Python's `read_text()` /
  `write_text()` silently normalises the whole file to LF and turns a six-line
  patch into a 1900-line diff. Vendored third-party files get edited in binary
  mode.

- `$error` inside a generate block is a **warning** to Verilator --
  `%Warning-USERERROR` -- not an error, so an elaboration-time check written
  that way passes whatever the condition says whenever warnings are non-fatal,
  which is everywhere in this repository. Verified by writing the check with a
  deliberately false condition and watching the build succeed. What does fail
  is `initial assert (...) else $fatal(...)`, at run time. Prefer putting the
  check in a test that runs.

- A SystemVerilog comment whose first word is `verilator` is a pragma. Wrapping
  a sentence so that a line begins "// Verilator, and ..." is
  `%Error-BADVLTPRAGMA`, from a paragraph of prose.

- Verilator emits a DPI wrapper for every `import "DPI-C"` it parses, whether
  the testbench calls it or not, so a header declaring the whole project's DPI
  surface is an undefined symbol at link time in every testbench that
  implements less than all of it. One header per testbench.

## Simulation

- `parameter time ClkPeriod = 1ns; forever #(ClkPeriod / 2) clk = ~clk;` is an
  integer division. At a coarse enough time precision it yields zero, and
  `forever #0` is an infinite loop in zero time -- reported, a long way from the
  cause, as `%Error-DIDNOTCONVERGE: Inactive region did not converge`. Cost half
  an hour of suspecting the design, and two eleven-minute rebuilds. Name a half
  period; do not divide one.

- Reading a design's combinational `ready` from a procedural block after
  `@(posedge clk)` reads it *after* the design's own registers have updated at
  that edge. A transmitter that was not ready at the edge looks ready just
  afterwards, so the testbench drops `valid` believing the flit went, and it
  did not. Drive stimulus on the falling edge, and observe a handshake through a
  flag registered by the design's own clock. This showed up as five of six
  channels delivering and one silently losing every flit.

- `assert (...) else $error(...)` prints `%Error` and lets Verilator exit zero.
  Only `$fatal` fails the run. For an interface invariant `$fatal` is the right
  answer anyway -- once one is violated, everything observed afterwards is a
  consequence rather than evidence.

- A `--timing` evaluation loop must test `gotFinish()` immediately after
  `eval()`, before asking whether events are pending. `$finish` leaves nothing
  scheduled, so checking in the other order reports every successful run as a
  deadlock.

- **Do not hand-write that loop.** Verilator's `--main` generates it, and at
  5.046 the generated loop is character-for-character the one above, ordering
  and all -- `src/V3EmitCMain.cpp` emits `if (!topp->eventsPending()) break;`
  after `eval()` exactly when `--timing` is on. So the whole of a testbench's
  C++ was three lines nobody needed to have written. `--main` is not in
  rules_verilator's managed-vopt reject list, so it goes straight into `vopts`;
  the generated `V<top>__main.cpp` is swept into the static library and a
  `cc_test` with **no `srcs` at all** links it, because `main` is undefined in
  crt and the linker pulls the archive member.

- What `--main` does not do is decide a verdict: the generated `main` always
  returns 0. So anything riding on the exit status has to move into the
  SystemVerilog, which is where it belonged. `$fatal` is the only thing that can
  fail a run now -- verified by planting a watchpoint that could not be
  satisfied and watching Exit 1 come back. Two consequences worth knowing:
  Verilator's `gotError()` no longer fails a run, so a bare `%Error` without
  `$fatal` passes; and the C++ deadlock detector is gone, which costs nothing
  here because a `forever` clock never runs out of events and the real hang --
  clock running, nothing concluding -- is a testbench timeout, not a C++ one.

- A negative test needs to fail *for the stated reason*. Ours takes the expected
  message as an argument, because the first version passed on an unrelated
  assertion in a different module -- the testbench had frozen a credit signal
  and three transmitters overflowed at once, which is a fault, but not the one
  under test.

- Verilating XiangShan with `--timing`: 676 s and 8187 actions the first time,
  ~130 s for a Verilator-only change afterwards. The model runs 1000 cycles in
  12 s. `--output-split 20000` is what keeps the C++ compiles parallel.

- A XiangShan cluster's first CHI request comes about 1040 cycles after reset,
  and that is CoupledL2 walking its directory to clear it rather than anything
  being wrong. A bring-up testbench needs a timeout well past that or it will
  conclude the link is dead.

- `mnstatus.NMIE` resets to zero in XiangShan's generated RTL, and Smrnmi makes
  any trap taken while it is zero a critical error rather than a trap. So
  `critical_error_o` early in a bring-up says "the core trapped", not "the core
  hit a hardware fault", and the interesting question is which trap.

  **It was a hardware-error exception, and the cause was ours.** CHI's
  `DataCheck` is odd parity per byte, and CoupledL2 checks it -- `RXDAT` computes
  `corrupt |= DataCheck[i] ^ ~^data[8i+7:8i]` over all thirty-two bytes of a
  beat. A home node that leaves the field zero is not declining to use it; it is
  asserting *even* parity for every byte, which is wrong for `0x00` among others.
  So every line was delivered marked corrupt, and the L1I turned that into
  `ExceptionNO 19` on the first instruction fetched. General lesson: an optional
  protocol field with a defined encoding is not optional if the receiver
  implements it, and zero is a value, not an absence.

- **A stuck signal has no edge, and "when did this rise" will not find it.**
  Walking the corrupt bit back through XiangShan's hierarchy worked by asking,
  at each level, which signals first went high and when -- until it reached one
  that had been 1 since time zero and so reported no rising edge at all. That
  read as "never set" and nearly ended the hunt at the level above. When a search
  for an edge comes back empty, read the value before concluding the signal is
  quiet.

- One FST of the failing run beat five rounds of hypothesis-and-rebuild. The
  earlier attempts changed the program, the reset length and the timer, and
  between them established only that the core was not at fault -- which is real
  information, and not the answer. Waveform first, next time: the run is ~1120
  cycles and the whole-hierarchy FST of 1868 modules is 3 MB.

- Test the seam, not just the two things either side of it. The link had a test
  with no protocol and the protocol had a test with no link, and the bug hunt
  that followed would have been an hour shorter if something had covered the
  DPI boundary between them. The agent test that fills that gap took twenty
  minutes to write and immediately ruled out half the hypotheses.


## Formatting

- rules_lint picks a language's files with GitHub Linguist's patterns, and
  Linguist knows `BUILD.bazel` but not `foo.BUILD.bazel` — the name a BUILD file
  takes when it is written for an external repository. In a repository whose
  whole third-party strategy is `<name>.BUILD.bazel` overlays, that is most of
  the Starlark, skipped in silence. The check looked green because it never
  looked. Patched in `//tools/format:patches/`; the pattern list already carries
  `*.MODULE.bazel`, so the fix is one word.

  The general form: a formatter that selects files by pattern will quietly not
  cover a naming convention nobody upstream has heard of. Count the files it
  reports against the files the tool reports when run by hand, once, at the
  start.

- Two modules using the same module extension disagree if one marks it a dev
  dependency and the other does not: rules_multitool sorts every hub tag into
  `root_module_direct_deps` or `root_module_direct_dev_deps` by
  `is_dev_dependency`, which is False for any non-root module, and Bazel refuses
  a name appearing in both lists. Adding aspect_rules_lint therefore forced
  rules_multitool to stop being a dev dependency here. The error names the
  extension and not the second module that started using it.

- `**kwargs` cannot be passed in a BUILD file, only in a `.bzl`. A dict shared
  between two macro calls — the formatter and the test that checks it — has to
  live in a `.bzl` and be spread there.

- buildifier reads `MODULE.bazel` as a module file and applies BUILD-file rules
  to it: multi-argument extension tag calls get one argument per line, and rule
  attributes are sorted into its canonical order. Comments move with the
  attribute they sit above, so nothing comes detached, but a hand-curated
  `MODULE.bazel` will churn on first contact.

- A whole-tree formatter and a long-lived branch are a bad pair. `style: format
  the tree` formatted the tree *as it was*; rebasing it onto forty files that
  arrived from another branch leaves those unformatted, and nothing says so until
  the format test runs. Rebase first, format second — the reverse silently
  formats a tree that is about to change.

- rules_lint honours `.gitattributes`. `format.sh` runs `git check-attr
  rules-lint-ignored linguist-generated gitlab-generated` and skips a file when
  any of the three is `set` or `true`; `disable_git_attribute_checks` turns that
  off and defaults to False. It is the supported way to keep the formatter off a
  vendored tree, and for `hardware/vip/chi/chiron` it earns its keep twice:
  reformatting would break the patches in `chiron/patches/` *and* normalise the
  CRLF that the lesson above this one is about.

## Python

- A **virtual** uv project's `[project].dependencies` are locked and reachable by
  nothing. aspect_rules_py's uv extension materialises a Bazel target only for
  packages a *dependency group* pulls in, so with `[tool.uv] package = false`
  the runtime deps resolve into `uv.lock` and then `@pypi//jinja2` does not
  exist. Symptom is a missing target, which reads like a typo. Put everything in
  `[dependency-groups]`.

- Choosing a dependency group is a **build flag**
  (`@aspect_rules_py//uv/private/constraints/dep_group:dep_group`), and each
  package is `target_compatible_with` the groups that name it. So two groups
  means a configuration transition on every target that uses the second one, and
  the error when the flag is unset is "didn't satisfy constraint
  @@platforms//:incompatible" -- which says nothing about dependency groups. One
  group, set in //.bazelrc, unless there is a real reason for two.

- `default_build_dependencies` on `uv.project()` may only name packages the
  lockfile resolves. `build` and `setuptools` are not implicit; without them
  every package whose lock entry carries an sdist alongside its wheels fails
  with "No module named build", from a venv the extension builds and nobody
  asked for.

- rules_py 2.0.0-alpha.6 builds **pydantic-core from its sdist even though the
  lockfile has a wheel for the interpreter in use**, and then wants maturin --
  a Rust toolchain, to validate a YAML file. `[tool.uv] no-build = true` does not
  prevent it; uv records the sdist either way and rules_py picks it. Confirmed
  by bisecting with a two-target probe: jinja2 + pyyaml built fine, pydantic
  alone failed. The fix that stuck was not using pydantic. Worth re-testing on a
  later alpha, and worth remembering as the general shape: in this repository a
  Python dependency with a compiled extension is a dependency on a toolchain,
  and should be argued for rather than assumed.

- Pin `requires-python` to one minor version, not a range. A range makes uv
  resolve for every version in it, which widens the set of packages rules_py
  thinks it may have to build from source. uv then rewrites `>=3.13,<3.14` as
  `==3.13.*` in the lock, so a test that asserts the spelling fails; assert the
  property. The version to pin to is whichever python-build-standalone
  aspect_rules_py fetches -- 3.13 at 2.0.0-alpha.6, visible as
  `aspect_rules_py++python_interpreters+python_3_13_*` in the external directory.

- A py_binary's `main` runs as a *script*, not as `python -m pkg`, so it has no
  parent package and `from .config import ...` raises "attempted relative import
  with no known parent package". With `imports` pointing at the directory above
  the package, an absolute import works from both.

- Setting a Starlark build setting in `//.bazelrc` changes the configuration of
  **every** target, not just the ones that read it: the flag becomes part of the
  configuration hash, output paths gain an `-ST-<hash>` component, and nothing
  in the tree is cached any more. Done here to select a uv dependency group, it
  turned a one-second Python test into a from-source rebuild of Verilator, twice
  -- 510 seconds against the 10,650 action-cache hits the same command gets with
  the flag removed. rules_py's venv rules take `dep_group` as a per-target
  attribute, which is the mechanism to reach for.

  General form: a repository-wide flag to satisfy one target is a repository-wide
  cache invalidation, and in a tree that builds its own toolchains that is not a
  small thing. Prefer the attribute; if there is no attribute, prefer a
  transition; put it in `.bazelrc` only when it genuinely applies to everything.

## Shell

- macOS ships **bash 3.2** -- 2007, GPLv2, and Apple will not ship a newer one.
  So no `mapfile`/`readarray`, no associative arrays, no `${x^^}`. The portable
  form of reading NUL-separated output is the `while IFS= read -r -d ''` loop
  that `tools/githooks/pre-commit` already used; `mapfile -d ''` looks cleaner
  and fails only on the developer machines this repository is written on.

- A file in a runfiles tree is a **symlink to** the source file, so `dirname` of
  its path is the runfiles directory, not the source directory. Resolve the link
  first and then take the directory; `pwd -P` on the runfiles path resolves the
  wrong thing and yields a plausible-looking answer.

- `.git` is a **file**, not a directory, inside a git worktree. A `[[ -d .git ]]`
  guard is false in exactly the setup this repository is developed in.

## Hardware verification

- **Opcode zero is an L-Credit return on every CHI channel**, so a flit built by
  setting the fields a test cares about and leaving the rest at zero is not a
  message -- it is flow control, and a correct receiver consumes it and passes
  nothing on. Cost an hour of tracing a crosspoint that accepted a flit and
  emitted nothing, which is exactly what it should have done. Any testbench
  constructing a CHI flit has to set an opcode on purpose.

- An unpacked array of queues (`int q[N][$]`) does not survive Verilator: writing
  one element was observed to change another, which surfaced as a perfectly
  correct flit failing an ordering check against a *different* pair's
  expectation. Both the two-dimensional and the flattened form did it. Where a
  scoreboard can be expressed as counters -- per-pair sequence numbers rather
  than per-pair queues -- it should be, and it is smaller anyway.

- The `%Error-BADVLTPRAGMA` entry above was walked into again, from a comment
  reflowed so that a line began "Verilator supports a subset...". Knowing the
  rule is not enough, because the trap is sprung by *rewrapping* a paragraph
  rather than by writing one. Never let a comment line start with that word.

- `fork`/`join_none` with `automatic` variables produced `no member named
  '__Vm_deleter'` from the generated C++ rather than a diagnostic. One process
  per port, started from a generate loop, expresses concurrent stimulus without
  any of it -- and reads better, since each port's driver is a thing rather than
  a fragment of a loop body.

- A latency budget written from a block diagram charged a crosspoint two cycles,
  one to buffer and one to arbitrate. Arbitration is combinational, so it is one
  cycle, and the whole fabric was a cycle per hop faster than its own
  documentation. **Count registers, not stages**: on this path every register
  costs a cycle and nothing else costs anything, which makes the number
  derivable rather than estimated. Measuring it took one test over every
  ordered pair and settled it in a second.

- A traffic pattern that maps a node to itself is a node addressing its own
  NodeID, which a crosspoint asserts on and is right to. Transpose fixes every
  device on the diagonal; hotspot makes the target one of the sources. Both are
  standard patterns and both need the same guard, so it belongs once in the
  destination function rather than in each pattern -- "no device addresses
  itself" is a property of traffic, not of one pattern.

- A "floor" in a throughput test is a **ratchet, not a specification**. The one
  written into the README before measuring said 0.45; the measurement said
  0.433, which is a perfectly good number for dimension-ordered routing with
  head-of-line blocking. Guessing a floor and then discovering the design misses
  it invites the wrong argument. Measure, set the floor just under, and say in
  the file that raising it is the point.

- `git ls-files` lists only *tracked* files, so a check built on it does not see
  a file that has just been written -- which is exactly when a person runs it.
  Use `--cached --others --exclude-standard` where the question is "does the
  tree build", and plain `ls-files` only where the question is genuinely about
  what is in the history.

- **A number that determines throughput should be measured before it is
  defaulted.** The credit count was set to four from a comment reasoning that
  "a credit takes three cycles to come back". It takes five. Every link in the
  fabric ran at 80% of line rate -- contended or not, loaded or idle -- and
  nothing failed, nothing warned, and the throughput tests passed against floors
  that had been set from the same wrong design. Raising it to six moved uniform
  traffic 39%.

- The way to find that was a **control with no contention in it**: a permutation
  where every input has exactly one destination and no two streams share a
  directed link, so nothing can block anything. Whatever it reaches is what the
  fabric does unobstructed, and everything below it in the other patterns is
  contention. Without that row, 43% looked like a plausible mesh number and the
  first plausible explanation -- head-of-line blocking, which is real and *was*
  there -- would have been accepted and optimised against. Measure the
  unobstructed case first; it is the cheapest number to get and it calibrates
  every other one.

- A ceiling asserted in a test is as capable of being wrong as a floor. Hotspot
  was quoted against 1/16 on the reasoning that sixteen devices addressed one
  destination. They address two -- a device may not address itself, so the
  target's own traffic goes elsewhere -- and the improved design correctly
  exceeded a bound that was never right. Compute a ceiling from what the test
  actually does, not from what the pattern is called.
