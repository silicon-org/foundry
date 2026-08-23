"""//:uv.lock against //:pyproject.toml.

Not the strong property. Proving the lock is what uv *would* resolve means
re-resolving, which needs the index, and a test that reaches the network is a
test that fails for reasons unrelated to the change under review. `bazel run
//:uv_lock` is where that happens, deliberately, by a person.

What is checked here is the failure that actually occurs: somebody adds a
dependency to pyproject.toml and does not relock, so the build fetches an
interpreter with no such package and fails somewhere unhelpful. That is pure
text, needs nothing, and runs with the rest of the suite.
"""

from __future__ import annotations

import re
import tomllib
from pathlib import Path


def _root() -> Path:
    """The workspace root, from here or from a runfiles tree."""
    here = Path(__file__).resolve()
    for candidate in here.parents:
        if (candidate / "pyproject.toml").exists() and (candidate / "uv.lock").exists():
            return candidate
    raise AssertionError("no pyproject.toml and uv.lock above this test")


ROOT = _root()
PYPROJECT = tomllib.loads((ROOT / "pyproject.toml").read_text())
LOCK = tomllib.loads((ROOT / "uv.lock").read_text())

LOCKED = {package["name"]: package for package in LOCK["package"]}


def _requirements() -> list[str]:
    groups = PYPROJECT.get("dependency-groups", {})
    direct = PYPROJECT.get("project", {}).get("dependencies", [])
    return [spec for group in groups.values() for spec in group] + list(direct)


def _name_of(spec: str) -> str:
    # "jinja2>=3.1" -> "jinja2". Normalised the way a lockfile spells it.
    return re.split(r"[><=!~\[;]", spec, maxsplit=1)[0].strip().lower().replace("_", "-")


def test_every_declared_dependency_is_locked():
    missing = [spec for spec in _requirements() if _name_of(spec) not in LOCKED]
    assert not missing, f"not in uv.lock; run `bazel run //:uv_lock`: {missing}"


def test_the_lock_targets_one_interpreter():
    """An open range makes uv resolve for versions rules_py never runs.

    Not pedantry: it is what made rules_py build pydantic-core from its sdist
    and then ask for a Rust toolchain. See the comment in pyproject.toml.

    The property, not the spelling -- uv rewrites `>=3.13,<3.14` as `==3.13.*`,
    and which of those it writes is uv's business.
    """
    spec = LOCK["requires-python"]
    assert "3.13" in spec, spec
    assert not spec.strip().startswith(">=") or "<" in spec, (
        f"requires-python is open-ended ({spec!r}); pin it to one minor version"
    )


def test_the_project_declares_no_bare_dependencies():
    """They would be locked and unreachable.

    rules_py materialises a Bazel target only for packages a dependency *group*
    pulls in, so anything under `[project].dependencies` resolves into the
    lockfile and then cannot be depended on -- which looks like the package not
    existing at all.
    """
    assert PYPROJECT["project"]["dependencies"] == []


def test_build_backends_are_declared():
    """//MODULE.bazel names these as default_build_dependencies.

    That setting can only reference packages the lockfile resolves, and without
    them the extension fails with "No module named build" for any package whose
    lock entry carries an sdist -- which is most of them.
    """
    for required in ("build", "setuptools"):
        assert required in LOCKED
