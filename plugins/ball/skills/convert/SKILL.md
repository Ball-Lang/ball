---
name: convert
description: This skill should be used when the user asks to "convert this codebase to <language>", "port this project to TypeScript/C#/Rust/Dart/C++", "migrate this service to another language", "transpile this package", or invokes /ball:convert <target>[, custom instructions] — including converting the surrounding tooling (build config, CI/CD, tests) and assessing whether such a conversion is feasible.
---

# Ball Convert — whole-codebase language conversion through the Ball IR

Argument form: `/ball:convert <target-language>[, <custom instructions>]` — arguments: "$ARGUMENTS"

This document is a **binding contract**, not advice. Follow the sections in order; the gates are blocking.

## What this is

Ball is a compiler-grade conversion pipeline, not an LLM rewriting aid. A per-language **encoder** lifts source code into a language-neutral protobuf IR (a `.ball.json` file — every program is a Protocol Buffer message), and a per-language **compiler** emits target-language source from that IR. The same IR also **executes directly** on Ball engines, which provides a correctness oracle no manual rewrite has. Ball's own multi-thousand-line engine is maintained exactly this way — one Ball program compiled to Dart, TypeScript, C++, and Rust, gated by a 300+-fixture conformance corpus — so treat the pipeline as production machinery and route the mechanical bulk of any conversion through it.

## Read this before dismissing the pipeline

Baseline agents reliably talk themselves out of the pipeline with the rationalizations below. All three are wrong; do not repeat them:

| Rationalization | Reality |
|---|---|
| "Ball only handles code written against its own std library, not arbitrary production code" | Encoders lift arbitrary source constructs (classes, generics, closures, cascades, spreads, control flow) INTO the universal std IR — that is their entire job. The true boundary is third-party dependencies and platform FFI. Inventory those specifically (§4); never use them to dismiss the whole codebase. |
| "No production-grade transpiler exists for this language pair" | Run the §3 probe before asserting this. If one representative file survives encode → compile → run, the claim is dead; if it does not, the failure output is scoping data, not a verdict. |
| "A careful hand rewrite with tests is safer" | Hand rewrites carry correlated author blind spots — tests translated in lockstep inherit the same misreadings as the code. The deterministic pipeline confines human/LLM judgment to the residual few percent (§5, Lane C) and verifies the rest mechanically (§8). |

## §0 Environment and permission discovery

Run before anything else, in the **user's repository** (the one being converted):

1. `git remote -v` and `gh api repos/<owner>/<repo> -q .permissions` (when the repo is on GitHub and `gh` is available). Classify: **maintainer** (push: true), **contributor** (fork + PR only), or **local-only** (no `gh`/remote). Never merge anything without maintainer rights and an explicit ask; contributors stop at PR; local-only stops at branches + a written plan.
2. Confirm a clean working tree — if it is dirty, stop and ask the user to commit or stash before proceeding (never convert over uncommitted work). Create a dedicated branch (or worktree) for the conversion. Tag the last pre-conversion commit — it is the rollback point and the §8 baseline.

## §1 Parse the request

From "$ARGUMENTS" extract: the **target language**, and any **custom instructions** (style rules, scope limits, naming conventions). Detect the **source language(s)** from the codebase itself (manifests, file extensions). Record custom style instructions now — they are implemented in §6 via the emitter, never as post-hoc file edits.

## §2 Feasibility gate (BLOCKING)

A conversion needs BOTH ends of the pipeline: an **encoder for the source language** and a **compiler for the target language**.

1. Read `references/toolchain-matrix.md` for the last-verified per-language status and install paths.
2. **Re-verify at run time** — statuses drift. Check the registries listed there and the Ball repo's CI (`.github/workflows/ci.yml` in `Ball-Lang/ball`) rather than trusting prose.
3. If the target has no Ball compiler (for example C#: proto bindings only, no compiler, no encoder, no engine): **STOP.** Report the gap, and offer `/ball:new <target>` as the prerequisite epic — that is multi-day compiler engineering tracked separately, not a step of this conversion. Do **not** silently degrade into a hand rewrite and call it the conversion.

## §3 Prove the pipeline in the first ten minutes

Before planning anything large:

1. Install the source-side and target-side toolchains per `references/toolchain-matrix.md`.
2. Pick ONE representative source file — selection criteria: a leaf of the import graph (no internal imports), pure logic (no FFI, no platform APIs), exercising the codebase's typical idioms — and push it through: encode → `ball validate` → target compile → run/compare (for Dart sources, `ball round-trip <file.dart>` performs encode → compile → diff in one step). Cross-language emission uses the TARGET language's own compiler — the Dart `ball` CLI has no `--target` flag (see `references/toolchain-matrix.md`).
3. On failure: capture the exact unsupported construct verbatim, check the Ball issue tracker for it, and treat it as §4 bucket data. On success: the pipeline is proven for this codebase; proceed.

## §4 Inventory the codebase

1. **Census**: source files, test files, build manifests, CI workflows, scripts, generated files (generated inputs are excluded — regenerate them in the target ecosystem instead of converting them).
2. **Import graph** → conversion order (leaves first).
3. **Encoder sweep**: run the encoder over EVERY source file (cheap and deterministic). Bucket the results: *clean* / *encodes-with-warnings* / *fails*. The bucket sizes are the honest **automation ratio** — report it to the user before committing to a plan.
4. **Dependency audit**: third-party dependencies do NOT convert (they are not this codebase's source). For each: (a) map to a target-ecosystem equivalent, (b) write a shim behind an interface, (c) for Ball-portable, source-available Dart pub dependencies ONLY, `ball build` can encode them on the fly from pub.dev — this is not a general escape hatch from dependency mapping and does not apply to ordinary ecosystem libraries, or (d) leave behind an adapter for later. Flag anything with no equivalent as a risk item up front.
5. **Checkpoint**: use AskUserQuestion to confirm scope (full codebase vs core first), dependency mapping choices, and style requirements before converting.

## §5 Convert in three lanes

- **Lane A — mechanical bulk** (the *clean* bucket): per-file/package encode → `.ball.json` IR → target compiler emit. Never hand-edit emitted files; fix the IR or the emitter and regenerate (same discipline as any generated code).
- **Lane B — bulk structural transforms**: renames, module regrouping, file-name mapping, and style-bearing metadata changes are deterministic scripts over the IR JSON — see `references/ir-transforms.md`. Token cost is O(script), not O(codebase).
- **Lane C — residuals** (the *fails* bucket): constructs the encoder cannot lift (FFI, isolates/threads beyond std_concurrency, reflective code). Hand-port ONLY these, each with characterization tests captured from the original. Keep the list short and report it verbatim in §9.

## §6 Style: put it in the emitter, never in edits

Custom style instructions ("keep our 4-space indent", "PascalCase file names") are implemented with the three levers in `references/style-customization.md`, cheapest first: (1) formatter configuration in the target ecosystem, (2) cosmetic `metadata` on the IR — provably semantics-preserving, because stripping all Ball metadata never changes what a program computes, (3) extending the target compiler's emission layer. One emitter change styles every emitted file forever; per-file LLM edits are the anti-pattern.

## §7 Convert the tooling, not just the source

1. **Build config**: translate the manifest (`pubspec.yaml` ⇄ `package.json` / `Cargo.toml` / `.csproj`), mapping dependencies per the §4 audit.
2. **Tests**: route test sources through the same encode→compile pipeline where encodable; map runner idioms (`package:test` ⇄ vitest / cargo test / xunit) for the rest.
3. **CI**: mirror the existing workflow shape — same triggers and matrix, swapped setup actions and commands.
4. **The rest**: scripts, lint configs, formatters, `.editorconfig`.

## §8 Parity verification — three oracles

1. **Baseline**: the original suite on the original code at the §0 tag.
2. **Converted**: the translated suite on the emitted code.
3. **Engine oracle** (unique to this pipeline): execute the SAME IR under a Ball engine (`ball run`, or the target CLI) and diff outputs across original ↔ engine ↔ compiled target on golden inputs. This verifies the encoding and the emission independently — a luxury hand rewrites never get.

Give numeric precision (int64/double), date/time, and string-encoding behavior dedicated goldens; those are where conversions silently diverge even when tests pass.

## §9 Close-out

Report honestly: automation ratio actually achieved, the Lane C residual list, parity evidence and its coverage bounds, and every shimmed dependency. Obtain an independent review pass (never self-approve). Open a PR following the repository's own conventions; merge only with maintainer tier and an explicit request.

## Additional resources

- **`references/toolchain-matrix.md`** — verified per-language encoder/compiler/engine availability and install/build paths, including registry warnings.
- **`references/ir-transforms.md`** — the IR's JSON shape, the semantic/cosmetic boundary, and deterministic bulk-edit patterns.
- **`references/style-customization.md`** — the three style levers, plus how to customize encoders and extend engines.
