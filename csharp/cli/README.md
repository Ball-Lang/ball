# Ball.Cli

`ball` is the command-line tool for [Ball](https://github.com/Ball-Lang/ball), a programming
language where every program is a Protocol Buffer message. This package is the C#/.NET build of
the `ball` CLI, published as a [.NET global tool](https://learn.microsoft.com/en-us/dotnet/core/tools/global-tools).

## Install

```bash
dotnet tool install --global Ball.Cli
```

## Usage

```bash
ball run <program.ball.json>        # execute a Ball program
ball compile <program.ball.json>    # compile a Ball program to C# source
ball encode <source.cs>             # encode a C# source file into a Ball program
ball check <program.ball.json>      # parse and validate a Ball program
ball info <program.ball.json>       # inspect a program's structure
ball validate <program.ball.json>   # check a program's validity
ball tree <program.ball.json>       # print a program's module/import dependency tree
ball version                        # print the CLI's version
```

`run`/`compile`/`encode`/`check` execute via the self-hosted C# engine and the Ball → C#
compiler; `info`/`validate`/`tree`/`version` execute via the self-hosted cli-core. Both are built
into this package — no extra setup required.

See the [Ball repository](https://github.com/Ball-Lang/ball) for the language spec, the full
multi-language toolchain (Dart, TypeScript, C++, Rust, C#), and `csharp/AGENTS.md` for
implementation details.
