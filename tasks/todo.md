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

- [ ] CIRCT http_archive at the `firtool-1.149.0` tag
- [ ] Spike the overlay mechanism: vendored `overlay_directory` repo rule (a),
      falling back to a single root BUILD file (b)
- [ ] `circt-tblgen` cc_binary
- [ ] HW dialect end to end: `td_library` + `gentbl_cc_library` + `cc_library`
- [ ] Version header via genrule
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
- [ ] ImportVerilog at C++20 with exceptions, CIRCT proper stays C++17
- [ ] Moore dialect, MooreToCore, `//third_party/circt:circt-verilog`
- [ ] **Gate:** circt-verilog round-trips a common_cells design

## M6 — The loom seam

- [ ] No-op HW pass via `cc_plugin_library`
- [ ] lit test loading it through `--load-pass-plugin` + `--hw-pass-plugin`
- [ ] `third_party/circt/README.md` documenting the seam

## Review

_Filled in as milestones land._
