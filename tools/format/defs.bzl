"""The formatters, and the two targets that have to agree about them.

Split out of BUILD.bazel because a BUILD file may not pass `**kwargs`, and
naming each language twice is exactly the drift this file exists to prevent.
"""

load("@aspect_rules_lint//format:defs.bzl", "format_multirun", "format_test")

# Neither formatter is fetched by rules_lint.
#
# clang-format is the one inside the hermetic toolchain: a multicall symlink in
# the prebuilt seed that already had to be downloaded before anything could be
# compiled, for all four platforms. So it costs nothing, and the formatter moves
# when the compiler moves rather than drifting from it.
#
# buildifier is a //tools:multitool.lock.json pin like every other CLI here,
# which is what makes `bazel run //tools:update` bump it and
# `bazel run //tools:versions` report it.
_FORMATTERS = {
    "c": "@llvm//tools:clang-format",
    "cc": "@llvm//tools:clang-format",
    "starlark": "@multitool//tools/buildifier",
}

def format_and_test(name = "format"):
    """Declares the formatter and the test that fails when sources disagree with it.

    Args:
        name: the runnable target; the test is `<name>_test`.
    """
    format_multirun(
        name = name,
        visibility = ["//visibility:public"],
        **_FORMATTERS
    )

    # no_sandbox, which is a trade rather than an oversight. rules_lint tags such
    # a test no-sandbox/no-cache/external, so it runs locally on every invocation
    # instead of being cached or shipped to a worker. What it buys is the files
    # no Bazel package owns -- .github/workflows, tasks/*.md, the root dotfiles --
    # which the hermetic form cannot reach, because that one checks a list of
    # srcs and a list only ever holds what somebody remembered to add. The whole
    # tree costs about a second.
    format_test(
        name = name + "_test",
        fix_target = ":" + name,
        no_sandbox = True,
        workspace = "//:MODULE.bazel",
        **_FORMATTERS
    )
