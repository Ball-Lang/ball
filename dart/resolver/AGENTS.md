<!-- Parent: ../AGENTS.md -->

# resolver (`ball_resolver`)

## Purpose
Module resolver for Ball programs: fetches, verifies, and caches modules from HTTP, file, git, inline, and registry sources, with integrity checking. Also adapts external package ecosystems (pub/npm) into Ball modules.

## Key Files
| File | Description |
|------|-------------|
| `lib/resolver.dart` | `ModuleResolver` — resolution entry point |
| `lib/cache.dart` | On-disk module cache |
| `lib/integrity.dart` | Hash/integrity verification |

## Subdirectories
| Dir | Contents |
|-----|----------|
| `lib/fetchers/` | Source fetchers: `http_`, `file_`, `git_`, `inline_fetcher.dart` |
| `lib/adapters/` | Ecosystem adapters: `pub_`, `npm_`, `registry_adapter.dart`, `registry_bridge.dart` |

## For AI Agents
- Entry point: `ModuleResolver`. Add a new source type by implementing a fetcher in `lib/fetchers/`; add an ecosystem by implementing an adapter in `lib/adapters/`.
- Integrity verification is mandatory — route new sources through `integrity.dart`, don't bypass the cache.
- Core invariants in `../../CLAUDE.md`; Dart patterns in `.claude/rules/dart.md`.
- Tests in `test/`.

## Dependencies
- Internal: `ball_base`.
- External: `http`, `archive`, `crypto` (integrity), `path`, `pub_semver`.
