"""Build hook for the combining `ball-lang` distribution: never ship generated code.

Everything declarative lives in pyproject.toml; this file exists for one
structural reason (issue #496).

`ball_engine/compiled_engine.py` is a ~690 KB GENERATED artifact — gitignored,
written by `python -m ball_engine.regen`, and present in any tree that has run
the self-host regeneration (every CI job that runs the conformance sweep does).
`[tool.setuptools] packages = ["ball_engine", ...]` sweeps in every `.py` in that
directory, so a wheel built after a regen would silently ship it — defeating the
whole compile-on-first-use design and the repo's "never distribute generated
code" rule. setuptools' declarative config has no per-module exclusion
(`exclude-package-data` covers data files only), so the filter lives here, in
`build_py`, where it applies to both the wheel and the sdist regardless of build
order or which workflow triggers it.

The wheel smoke (`python/tool/wheel_smoke.py`) asserts the result: the built
wheel must NOT contain `ball_engine/compiled_engine.py`, and `ball run` must
compile the bundled source into the cache dir.
"""

from __future__ import annotations

from setuptools import setup
from setuptools.command.build_py import build_py

#: (package, module) pairs that are generated build artifacts, never shipped.
EXCLUDED_MODULES = {("ball_engine", "compiled_engine")}


class BuildPyWithoutGeneratedModules(build_py):
    def find_package_modules(self, package, package_dir):
        return [
            (pkg, module, path)
            for (pkg, module, path) in super().find_package_modules(package, package_dir)
            if (pkg, module) not in EXCLUDED_MODULES
        ]


setup(cmdclass={"build_py": BuildPyWithoutGeneratedModules})
