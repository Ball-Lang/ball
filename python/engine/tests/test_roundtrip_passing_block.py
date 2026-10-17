"""``conformance.roundtrip``'s per-fixture PASS SET block (issue #896,
generalizing #836's Rust fix to the C#/Go/Python round-trip legs).

A pass-COUNT floor cannot tell "nothing changed" from "one fixture newly
passes while a different one regresses" -- the printed ``Results:`` count is
identical either way, so ``tools/ci/roundtrip_passset.sh`` diffs the SET
``_format_passing_block`` prints against a committed baseline instead.
Mirrors ``rust/engine/tests/roundtrip_conformance.rs``'s own
``format_passing_block`` tests.

The module under test is loaded by FILE PATH rather than
``from conformance.roundtrip import ...``: ``python/compiler/conformance/``
is a real package (has an ``__init__.py``) that shadows the namespace
package ``python/engine/conformance/`` the instant ``python/compiler`` lands
on ``sys.path`` ahead of ``python/engine`` -- which is exactly the order this
suite's own ``conftest.py`` sets up, so the dotted import would silently
resolve to the WRONG ``conformance`` package and fail with a confusing
``ModuleNotFoundError: No module named 'conformance.roundtrip'``.
"""

from __future__ import annotations

import importlib.util
import sys
from pathlib import Path

_ROUNDTRIP_PATH = Path(__file__).resolve().parents[1] / "conformance" / "roundtrip.py"


def _load_roundtrip_module():
    name = "ball_engine_test_roundtrip"
    spec = importlib.util.spec_from_file_location(name, _ROUNDTRIP_PATH)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    # `dataclasses.dataclass` looks itself up via `sys.modules[cls.__module__]`
    # while the class body is still executing, so the module must be
    # registered BEFORE exec_module runs its top-level `@dataclass` decorators.
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


_format_passing_block = _load_roundtrip_module()._format_passing_block


def test_header_names_the_count_and_lists_every_fixture_two_space_indented():
    block = _format_passing_block(["100_a", "101_b"])
    assert block == "Passing fixtures (2, sorted):\n  100_a\n  101_b\n"


def test_an_empty_passing_set_still_prints_a_well_formed_header():
    assert _format_passing_block([]) == "Passing fixtures (0, sorted):\n"


def test_a_net_zero_fixture_swap_changes_the_printed_block():
    """THE regression this block exists to let a set-difference gate catch:
    same cardinality, different membership -- a bare count could never
    distinguish these two sets."""
    before = ["100_a", "101_b", "102_c"]
    after = ["100_a", "102_c", "103_d"]  # 101_b regressed, 103_d is new

    assert len(before) == len(after), "the scenario is a net-zero swap by construction"
    assert _format_passing_block(before) != _format_passing_block(after)
