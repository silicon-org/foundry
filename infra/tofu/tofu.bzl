"""Hermetic OpenTofu entrypoints.

Bazel *invokes* tofu at a pinned version; it does not model tofu state. Tofu
owns provisioning state, and that state lives in the source tree next to the
`.tf` files -- not in a Bazel sandbox that gets thrown away. So these targets
run tofu with its working directory set to the module inside
`$BUILD_WORKSPACE_DIRECTORY`.
"""

load("@rules_shell//shell:sh_binary.bzl", "sh_binary")

_TOFU = "@multitool//tools/tofu"

def tofu_command(name, module, subcommand = None):
    """Declares `bazel run` wrapper for one tofu subcommand.

    Args:
        name: target name, also the default subcommand.
        module: workspace-relative path of the tofu root module.
        subcommand: tofu argv to run, defaults to [name].
    """
    sh_binary(
        name = name,
        srcs = ["//infra/tofu:tofu_wrapper.sh"],
        args = ["$(rlocationpath {})".format(_TOFU), module] + (subcommand or [name]),
        data = [_TOFU],
        deps = ["@bazel_tools//tools/bash/runfiles"],
    )
