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
    "hcloud": ["version"],
    # Writes a raw disk image into a Hetzner snapshot; how Talos gets onto a
    # cloud server at all, since Hetzner has no stock Talos image with the
    # extensions we need. See //infra/talos.
    "hcloud-upload-image": ["--version"],
    "helm": ["version", "--short"],
    "kubectl": ["version", "--client"],
    "multitool": [],
    # Checks PrometheusRule expressions at commit time. The Prometheus operator
    # does validate them, but it validates them in a controller log minutes
    # after a push, attached to nothing. See //infra/platform:promtool_test.
    "promtool": ["--version"],
    "sops": ["--version", "--disable-version-check"],
    "talhelper": ["--version"],
    "talosctl": ["version", "--client", "--short"],
    "tofu": ["version"],
    # Waveform query engine the debugging agents drive over MCP; see //.mcp.json.
    "tsunami-serve": ["--version"],
}

def tool_label(name):
    """Returns the rules_multitool label for a pinned tool."""
    return "@multitool//tools/" + name
