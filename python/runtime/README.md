# ballrt

The zero-dependency Python runtime for Ball programs compiled to Python by
`ball_compiler`. Python stdlib only, requires Python >= 3.11.

A compiled program `import ballrt` and calls the flat helpers re-exported from
`ballrt/__init__.py` (arithmetic, comparison, logic, strings, collections, flow
signals, console output) — all with Dart-exact semantics. See `AGENTS.md` for
the module map and the Dart-exact quirks.
