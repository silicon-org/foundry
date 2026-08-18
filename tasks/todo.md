# Build CIRCT from source with Bazel

Plan of record. Full reasoning, risks and verification live in the plan document;
this is the checklist.

Why: CIRCT publishes no linux/arm64 binary for any release variant, so RTL
generation cannot run on the local (Apple Silicon) cluster. Separately, loom
needs to link CIRCT, and slang is not present in any released firtool. All three
are answered by building CIRCT in this graph with this toolchain.

## M0 — Scaffolding

- [x] `tasks/todo.md` and `tasks/lessons.md`

## M1 — LLVM and MLIR in the build graph

- [x] `@llvm-raw` http_archive pinned to CIRCT's llvm submodule sha
- [x] `llvm_configure(name = "llvm-project")` via `use_repo_rule`
- [x] Repos the overlay references by name. Only four were actually needed:
      `bazel_skylib`, `rules_python`, `zlib-ng` as `llvm_zlib`, `zstd` as
      `llvm_zstd`. `apple_support`, `protobuf`, `rules_foreign_cc`,
      `rules_android` and the `llvm_repos_extension` repos (gmp, mpfr, mpc,
      nanobind, pyyaml, robin_map, vulkan) are declared by LLVM's own
      MODULE.bazel but are only reached by targets we do not build.
- [x] Reconcile the overlay's required flags with `//.bazelrc` -- nothing to do.
      The overlay's .bazelrc writes `-std=c++17`, `--features=layering_check`,
      `--force_pic` and friends as global flags, but none turned out to be
      load-bearing here: the hermetic toolchain's clang already defaults to
      gnu++17, and the rest are stricter-than-required settings LLVM uses on
      itself. Left alone rather than copied, so this repo's flags stay ours.
- [x] **Gate passed.** `@llvm-project//mlir:mlir-tblgen` builds for darwin/arm64
      (64s), linux/arm64 (89s) and linux/amd64 (68s), verified by `file` on the
      artifacts: ARM aarch64 and x86-64 Linux ELFs respectively.

## M2 — Overlay mechanism, circt-tblgen, one dialect

- [x] CIRCT http_archive at the `firtool-1.149.0` tag (9.6 MB, well under the
      CAS ceiling unlike llvm-project)
- [x] Overlay mechanism settled -- **(b), not (a)**. The single-file overlay is
      the repository's existing pattern, used by twelve archives already, and it
      works because CIRCT ships no BUILD files of its own, so the whole tree is
      one package. (a) would have needed a vendored copy of a private LLVM
      helper plus a way to stop BUILD files under //third_party being loaded as
      packages of this repository -- real machinery, for per-directory diffs.
- [x] `circt-tblgen` cc_binary -- builds in 64s, and `--help` lists all three
      FIRRTL backends the closure needs
- [ ] HW dialect end to end: `td_library` + `gentbl_cc_library` + `cc_library`
- [x] Version header via `expand_template` over `lib/Support/Version.cpp.in`,
      substituting `@CIRCT_VERSION@`. CMake derives it from `git describe`, so
      writing it from the pin is what keeps generation reproducible -- the same
      reasoning //MODULE.bazel gives for XiangShan's publishVersion.
- [ ] **Gate:** HW dialect lit tests pass

## M3 — firtool

- [ ] Remaining dialects in the firtool closure, derived from `LINK_LIBS`
- [ ] ExportVerilog, ImportFIRFile, per-dialect Transforms, Support,
      Target/DebugInfo, Firtool pipeline library
- [ ] `//third_party/circt:firtool`
- [ ] lit tests for every dialect touched
- [ ] **Gate:** firtool builds on all three platforms, lit tests green

## M4 — Cut over, delete the prebuilt

- [ ] Diff XiangShan RTL prebuilt-vs-source (one-time migration evidence)
- [ ] Point `//tools/firtool:firtool` at the source build
- [ ] Delete both firtool http_archives, `firtool.BUILD.bazel`, the select
- [ ] Rewrite the now-false arm64 comments
- [ ] **Gate:** `bazel build --config=remote //hardware/...` on arm64

## M5 — slang and circt-verilog

- [ ] slang http_archive at CIRCT's pinned sha
- [ ] Deps: fmt, tomlplusplus from BCR; Boost regex fork header-only
- [ ] genrules for `syntax_gen.py` / `diagnostic_gen.py`
- [ ] `SLANG_USE_THREADS` off; `SLANG_DEBUG` / `SLANG_ASSERT_ENABLED` as defines
- [ ] C++20. **Not** the per-target arrangement originally planned: the RTTI and
      exceptions half of the conflict does not exist here (see lessons.md), so
      what is left is the language standard alone. Decide global `-std=c++20`
      versus per-target `copts` when slang lands -- global avoids compiling MLIR
      headers at two different standards inside ImportVerilog's translation
      unit, which is an ODR hazard upstream's CMake lives with by setting
      CMAKE_CXX_STANDARD 20 for that directory only.
- [ ] Reference, not a dependency: hankhsu1996/slang carries a full bzlmod build
      on `feature/bazel-support-*` branches, including genrules that drive
      `diagnostic_gen.py` and `syntax_gen.py`. It is two major versions behind
      CIRCT's pin (declares 9.1.0 against v11.0+85) and lives on unmerged
      branches of a fork, so the pattern transfers and the code does not.
- [ ] Moore dialect, MooreToCore, `//third_party/circt:circt-verilog`
- [ ] **Gate:** circt-verilog round-trips a common_cells design

## M6 — The loom seam

- [ ] No-op HW pass via `cc_plugin_library`
- [ ] lit test loading it through `--load-pass-plugin` + `--hw-pass-plugin`
- [ ] `third_party/circt/README.md` documenting the seam

## Review

_Filled in as milestones land._
