---
name: conformance-hand-edit
enabled: true
event: file
conditions:
  - field: file_path
    operator: regex_match
    pattern: tests[/\\]conformance[/\\].*\.ball\.json$
action: warn
---

⚠️ **Conformance fixtures are generated.** `tests/conformance/*.ball.json` comes from `tests/conformance/src/<name>.dart` via `cd dart/encoder && dart run bin/generate_conformance.dart` — hand-edits get flagged by the Artifact Freshness CI gate. The only exceptions are the hand-authored fixtures documented in `tests/conformance/CARVEOUTS.md` (constructs no encoder can emit). If this file is one of those, proceed; otherwise edit the `src/` Dart file and regenerate.
