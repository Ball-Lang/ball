<!-- Parent: ../AGENTS.md -->

# docs

## Purpose
Design specifications, architecture plans, and post-mortem documents for the Ball project. No executable code lives here — these are authoritative references for AI agents and contributors.

## Key Files / Contents

| File | Description |
|------|-------------|
| `TESTING_STRATEGY.md` | Conformance-first testing philosophy; issue-#55 post-mortem; encoder-completeness gate rules |
| `METADATA_SPEC.md` | All known `metadata` keys and their semantics; update when adding new keys |
| `EDITIONS_SPEC.md` | Protobuf Editions feature-set model; §3 feature tables and known limitations |
| `SELF_HOST_STATUS.md` | Current C++ / TS self-hosted engine conformance gaps; kept current (not prose) |
| `PROTOBUF_CODEGEN_PLAN.md` | Design + status for `ball_protobuf_gen` + `ball_rpc`; target-language roadmap |
| `ASYNC_DESIGN.md` | Async evaluation model for the Ball engine |
| `IMPLEMENTING_A_COMPILER.md` | Step-by-step guide for writing a new Ball compiler |
| `CROSS_TARGET_STRATEGY.md` | Strategy for reaching full compiler+encoder+engine parity across targets |
| `CONFORMANCE_GAPS.md` | Known gaps in the cross-language conformance matrix; tracked failures |
| `STD_COMPLETENESS.md` | Coverage of `std`/`std_collections`/`std_io`/`std_memory` across all engines |
| `PATTERN_DESIGN.md` | Design rationale for Ball's pattern-matching constructs |
| `ARTICLE_REVIEW.md` | Reviewer notes for public-facing articles and blog posts |
| `scaling.md` | Performance and scaling notes for large Ball programs |

## For AI Agents

- **Read before implementing**: `TESTING_STRATEGY.md` (conformance rules), `METADATA_SPEC.md` (before touching metadata), `SELF_HOST_STATUS.md` (C++ / TS gaps).
- **Update after implementing**: `METADATA_SPEC.md` when adding new metadata keys; `SELF_HOST_STATUS.md` when C++/TS gaps are fixed or added.
- All files here are Markdown prose — never autogenerate them; write accurate, concise content.
- `EDITIONS_SPEC.md` is the spec; `dart/ball_protobuf/` is the implementation. Keep them in sync.
- Do not add new doc files without a concrete need; prefer updating existing ones.
