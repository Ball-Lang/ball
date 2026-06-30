# Conformance Test Suite

Cross-language test suite for Ball implementations. Each test is a `.ball.json` program. Most carry a matching `.expected_output.txt` file with the exact expected stdout; a handful of host-policy fixtures (e.g. timeout / memory-limit / sandbox-mode) have no expected-output file and are documented in [`CARVEOUTS.md`](CARVEOUTS.md).

The corpus is large and grows continuously — the authoritative list of fixtures is the contents of [`src/`](src/) (one `NN_<name>.dart` source per generated fixture), not any table in this file. Browse `src/` (or `ls tests/conformance/*.ball.json`) to see everything that exists.

## Running Tests

### Dart Engine

```bash
cd dart/engine
dart run ../../tests/conformance/run_conformance.dart --dir ../../tests/conformance
```

### C++ Engine (self-hosted)

The C++ self-host engine runs the corpus through CTest. Each fixture is registered
as a `selfhost/<name>` test (label `selfhost`) backed by the
`test_selfhost_conformance` target (see `cpp/test/CMakeLists.txt`):

```bash
# Configure + build the C++ tree
cmake -S cpp -B cpp/build && cmake --build cpp/build --target test_selfhost_conformance

# Run the whole self-host conformance corpus
ctest --test-dir cpp/build -L selfhost

# Run a single fixture
ctest --test-dir cpp/build -R "selfhost/01_hello_world"
```

## Test Programs

Fixtures are **generated**, not hand-listed. The canonical inventory lives in
[`src/`](src/) — each `NN_<name>.dart` source compiles to a matching
`NN_<name>.ball.json` (and, unless carved out, a `.expected_output.txt`). To see
what is covered, read the source files in `src/` or list the corpus:

```bash
ls tests/conformance/src/*.dart        # the source of every generated fixture
ls tests/conformance/*.ball.json       # the generated programs themselves
```

The C++ CTest registration globs `tests/conformance/*.ball.json` directly
(`CONFIGURE_DEPENDS`), so newly generated fixtures are picked up automatically —
there is no manual list to keep in sync.

## Adding a New Test

1. Write a Dart source in `src/NN_name.dart` (use only std-compatible features).
2. Run `cd dart/encoder && dart run bin/generate_conformance.dart` to generate the
   `.ball.json` and `.expected_output.txt` (host-policy fixtures with no expected
   output must be listed in [`CARVEOUTS.md`](CARVEOUTS.md), which CI enforces).
3. Verify with `cd dart/engine && dart test test/conformance_test.dart`.

The fixture is discovered automatically by the runners and the C++ CTest glob — do
**not** maintain a hand-written table of fixtures here (that is exactly the drift
this README used to suffer from).
