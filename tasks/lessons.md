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

  It matters beyond tidiness: a 139 MB output that changes for no reason defeats
  the action cache on every clean build and undercuts the reproducibility this
  repository is built around. Worth its own investigation; `--target firrtl`
  plus `--target-dir` is how to reproduce it in about three minutes without
  running firtool at all.

- When comparing two compilers, compare them on *one* input. Running the whole
  pipeline twice and diffing the ends conflates every stage; dumping the
  intermediate and feeding it to both binaries took the question from "216 names
  differ, why?" to a byte-identical hash in one step.
