<!-- Parent: ../AGENTS.md -->

# web/playground

## Purpose
Standalone browser playground for Ball. Runs the Ball engine entirely in-browser via a pre-compiled JavaScript bundle; no server needed.

## Key Files / Contents

| File | Description |
|------|-------------|
| `index.html` | Playground entry point; loads `app.js` and `style.css` |
| `app.js` | Main playground application logic (editor, run button, output panel) |
| `ball-engine.js` | Pre-compiled Ball engine bundle for in-browser execution |
| `style.css` | Playground styles |

## For AI Agents

- `ball-engine.js` is a **compiled artifact** — do not edit it by hand. Regenerate it from the TS engine (`ts/engine/`) when the engine changes.
- This playground is distinct from the Jaspr-embedded playground in `website/playground/`; they serve different deployment contexts (standalone static page vs. embedded in the website SSR app).
- Changes to `app.js` or `style.css` are hand-authored; no build step is required for those files.
- Test locally by opening `index.html` directly in a browser or serving the directory with any static file server.
