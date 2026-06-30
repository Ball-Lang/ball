<!-- Parent: ../AGENTS.md -->

# website

## Purpose
The ball-lang.dev public website built with Jaspr (Dart SSR). Renders the home page, docs, and examples. The `playground/` subdirectory contains the in-browser Ball playground (separate from `web/playground/`).

## Key Files / Contents

| Path | Description |
|------|-------------|
| `pubspec.yaml` | Jaspr package definition; workspace member |
| `lib/main.server.dart` | Jaspr server entry point |
| `lib/main.client.dart` | Jaspr client hydration entry point |
| `lib/pages/home.dart` | Landing page component |
| `lib/pages/docs.dart` | Documentation page |
| `lib/pages/examples.dart` | Examples browser page |
| `lib/components/navbar.dart` | Site navigation bar |
| `lib/components/footer.dart` | Site footer |
| `lib/components/code_block.dart` | Syntax-highlighted code display |
| `lib/components/feature_card.dart` | Feature highlight card |
| `lib/components/language_tabs.dart` | Multi-language code tab switcher |
| `lib/generated/` | Jaspr-generated files — do not edit |
| `content/` | YAML content files: `hello_world.ball.yaml`, `fibonacci.ball.yaml`, `fibonacci_function.ball.yaml` |
| `web/` | Static assets: `CNAME`, `manifest.json`, `robots.txt`, `styles.css` |
| `tool/generate_examples.dart` | Generates example content from `examples/` for the website |
| `build/` | Build output — do not edit |

## Subdirectories

- `lib/` — Jaspr Dart source (components + pages)
- `content/` — YAML Ball example data consumed by `generate_examples.dart`
- `web/` — Static files served at the root (not the `web/playground/` WASM playground)
- `playground/` — Jaspr-embedded playground component (distinct from `web/playground/`)

## For AI Agents

- This is a **Jaspr** (Dart SSR) app — follow `jaspr-rules` when modifying components. See `.claude/rules/` for Jaspr-specific conventions.
- `lib/generated/` and `build/` are generated — never edit them directly.
- To update example content shown on the site, edit `examples/<name>/<name>.ball.json` and re-run `dart run tool/generate_examples.dart` from this directory.
- The `web/` static assets here are separate from `web/playground/` (the standalone WASM playground at the root `web/` directory).
- After changes, build with `jaspr build` and verify with `jaspr serve`.
