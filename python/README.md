# ball-lang — the Ball language, Python toolchain

[Ball](https://github.com/Ball-Lang/ball) is a programming language where every
program is a Protocol Buffer message. This distribution bundles the whole Python
toolchain: the Ball → Python compiler, the Python → Ball encoder, the
self-hosted engine, the zero-dependency runtime, and the `ball` CLI.

```bash
pip install ball-lang
```

## Usage

```bash
ball --version                       # the installed toolchain version
ball check    program.ball.json      # validate without running
ball compile  program.ball.json      # Ball -> Python source        [-o out.py]
ball encode   source.py              # Python -> Ball program       [-o out.ball.json]
ball run      program.ball.json      # execute via the self-hosted engine
```

Programs are read as proto3 JSON (`.ball.json` / `.json`), optionally wrapped in
a `google.protobuf.Any` `@type` envelope.

Exit codes: `0` success · `1` runtime error · `2` invalid program / usage ·
`3` I/O error.

## First `ball run` compiles the engine

The Ball engine is itself a Ball program. Rather than ship a generated ~690 KB
Python module, this wheel carries the engine's Ball **source** and compiles it
with the bundled Ball → Python compiler the first time you run `ball run`,
caching the result. That takes well under a second; every later run reuses the
cache.

The cache lives in `%LOCALAPPDATA%\ball-lang\engine` on Windows and
`$XDG_CACHE_HOME/ball-lang/engine` (default `~/.cache/ball-lang/engine`)
elsewhere. Set `BALL_CACHE_DIR` to override it — useful in containers, CI, and
read-only-`HOME` environments. The cache key covers the installed version and a
hash of the bundled source, so an upgrade recompiles rather than reusing a stale
engine.

## Python API

```python
from ball_compiler.compiler import compile as compile_program
from ball_compiler.loader import load_program
from ball_encoder.encoder import encode

src = compile_program(load_program("program.ball.json"))
```

## License

MIT — see the [repository](https://github.com/Ball-Lang/ball).
