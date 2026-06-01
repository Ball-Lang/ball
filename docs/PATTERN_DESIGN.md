# Ball Pattern Matching Design

> 12 pattern kinds covering all 11 target languages (Dart, TS, C++, Rust, Python,
> Java, Go, Ruby, Kotlin, Swift, Scala, C#, Haskell).

## The 12 Pattern Kinds

| # | Kind | What It Covers |
|---|---|---|
| 1 | **Wildcard** | `_` in all languages |
| 2 | **Variable** | `var x`, `int x`, capture patterns |
| 3 | **Constant** | `42`, `"hi"`, enum values |
| 4 | **TypeTest** | `is Type`, cast, null-check, null-assert |
| 5 | **Destructure** | Tuples, records, constructors, positional/named |
| 6 | **List** | `[p1, p2, ...rest]`, slice patterns |
| 7 | **Map** | `{'key': pattern}`, mapping patterns |
| 8 | **Or** | `p1 \| p2`, alternatives |
| 9 | **And** | `p1 && p2`, conjunctive |
| 10 | **Relational** | `< 5`, `>= 10` |
| 11 | **Binding** | `name @ pattern`, `pattern as name` |
| 12 | **Rest** | `..`, `...rest`, `*rest` |

## Why 12 Is Minimal

- Fewer would require lossy encoding (stuffing patterns into guards or metadata)
- More would be redundant (parenthesized = tree structure, ranges = And+Relational)
- Guards live on Pattern, not match arms (supports Dart `if-case`)
- Metadata handles language-specific details (Rust ref/mut, Swift let/var)

## Language Coverage Matrix

Every pattern in every target language maps to one of these 12 kinds.
See full mapping table in the research output.

## Proto Schema

See `proto/ball/v1/ball.proto` for the implementation.
