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

