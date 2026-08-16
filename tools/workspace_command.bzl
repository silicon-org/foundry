"""Runs a Bazel-pinned CLI against a directory in the source tree.

Several of these tools own state that has to outlive a build: OpenTofu writes
state files, talosctl writes cluster state and a kubeconfig. Bazel pins their
versions and provides the entrypoint, but it deliberately does not pretend to
own what they produce. So these wrappers run in `$BUILD_WORKSPACE_DIRECTORY`
rather than in a sandbox that gets discarded.
"""

load("@rules_shell//shell:sh_binary.bzl", "sh_binary")

def workspace_command(name, tool, args = None, workdir = ".", **kwargs):
    """Declares a `bazel run` entrypoint for a pinned CLI.

    Args:
        name: target name.
        tool: label of the pinned tool, e.g. `@multitool//tools/tofu`.
        args: argv passed to the tool. Arguments after `--` on the command line
            are appended to these.
        workdir: workspace-relative directory to run in.
        **kwargs: forwarded to sh_binary.
    """
    sh_binary(
        name = name,
        srcs = ["//tools:workspace_command.sh"],
        args = ["$(rlocationpath {})".format(tool), workdir] + (args or []),
        data = [tool],
        deps = ["@bazel_tools//tools/bash/runfiles"],
        **kwargs
    )
