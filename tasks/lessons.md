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
