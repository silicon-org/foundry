"""nocgen's command line.

    bazel run //hardware/ip/chi_noc/nocgen -- --config <topology.yml> --out <dir>

Writes three files named after the topology. In the build they come from the
`nocgen_topology()` macro instead, so a generated mesh is a build output and not
something checked in and hoped to be current.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

import yaml

# Absolute, not relative. Bazel runs this file as a script rather than as
# `python -m nocgen`, so it has no parent package; `imports` puts the directory
# above on sys.path, which makes these work either way.
from nocgen.config import Topology
from nocgen.emit import render
from nocgen.network import elaborate


def load(path: Path) -> Topology:
    return Topology.parse(yaml.safe_load(path.read_text()))


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="nocgen", description=__doc__)
    parser.add_argument("--config", required=True, type=Path, help="topology YAML")
    parser.add_argument("--out", required=True, type=Path, help="output directory")
    parser.add_argument(
        "--name",
        help="override the topology name, and so the output file names",
    )
    args = parser.parse_args(argv)

    network = elaborate(load(args.config))
    artefacts = render(network, source=args.config.name)
    for written in artefacts.write(args.out, args.name or network.name):
        print(written)
    return 0


if __name__ == "__main__":
    sys.exit(main())
