"""Single source of truth for the monorepo's pinned CLI tools.

Adding a tool is a two-step change: add its binaries to `multitool.lock.json`,
then add one entry here. Everything else follows -- `//tools:bazel_env` puts it
on PATH and `//tools:versions` reports it -- so the two consumers cannot drift.

The value is the argument list that makes the tool print its own version; an
empty list means the tool has no version flag and is only pinned by the
lockfile. Prefer flags that stay offline (`--client`, `--disable-version-check`)
so `//tools:versions` never depends on a network or a cluster.
"""

TOOLS = {
    "age": ["--version"],
    "age-keygen": ["--version"],
    "cilium": ["version", "--client"],
    "flux": ["--version"],
    "gitleaks": ["version"],
    "helm": ["version", "--short"],
    "kubectl": ["version", "--client"],
    "multitool": [],
    "sops": ["--version", "--disable-version-check"],
    "talhelper": ["--version"],
    "talosctl": ["version", "--client", "--short"],
    "tofu": ["version"],
}

def tool_label(name):
    """Returns the rules_multitool label for a pinned tool."""
    return "@multitool//tools/" + name
