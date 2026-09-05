# CLI-core golden reports

The reference output of the portable `ball` verbs `info` / `validate` / `tree`,
produced by the **Dart-native** `cli_core` (`dart/shared/lib/cli_core.dart`) —
the single source of truth every other target's compiled `cli_core` is gated
against.

One canonical copy lives here rather than one per language (issue #570): Go's
`go/cli/cli_core_parity_test.go` and Python's
`python/cli/tests/test_cli_core_parity.py` both read these files, so the two
gates can never drift apart from each other while both stay green.

## Fixtures

The same five-fixture slice `dart/cli/test/cli_core_parity_test.dart` and
`rust/cli/tests/cli_core_parity.rs` use — deliberately varied (control flow,
classes, cascades, maps, sets):

    100_complex_control_flow  101_simple_class  111_cascade_operator
    116_map_iteration         118_set_operations

## Bytes

Each file is exactly what `ball <verb> tests/conformance/<fixture>.ball.json`
prints on stdout: the report text plus the single trailing newline every CLI
adds (Dart `writeln`, Go `Fprintln`, Python `stdout.write(report + "\n")`).
`.gitattributes` pins them to `eol=lf` so the byte comparison is identical on
every platform — a CRLF checkout would fail the gates for no real reason.

`version` has no golden: its whole logic is `"ball " + version`
(`cli_core.versionLine`), which each parity test asserts directly against the
compiled function, exactly as the Rust and Dart gates do.

`audit` has no golden here either — Go and Python do not ship an `audit` verb
(see `go/cli/AGENTS.md` / `python/cli/AGENTS.md`); Rust keeps its own
`audit` goldens under `rust/cli/tests/golden/cli_core/`.

## Regenerating

Only needed when `dart/shared/lib/cli_core.dart`'s report FORMAT changes (a
deliberate behavior change — these files are checked in, unlike
`cli.ball.json` / the compiled artifacts). From the repo root:

```bash
cd dart && dart run cli/tool/gen_cli_parity_goldens.dart <tmp_dir>
python tools/gen_cli_core_goldens.py <tmp_dir>   # copies the five fixtures,
                                                 # adding the CLI's trailing \n
```

`gen_cli_parity_goldens.dart` writes `cli_core`'s raw report text with **no**
trailing newline (it also serves the C++ `audit` gate, which compares the raw
bytes); the copier adds the one byte the CLIs' `writeln` contributes. Doing it
this way — rather than a `dart run … > golden` shell redirect — keeps the bytes
UTF-8-exact on a non-UTF-8 Windows console.
