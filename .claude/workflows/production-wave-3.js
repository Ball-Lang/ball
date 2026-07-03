export const meta = {
  name: 'production-wave-3',
  description: 'Nine lanes: engine bugs, coverage x3, conformance surface, protobuf replacement, docs/schema, snapshot stripping, cpp set literals',
  phases: [{ title: 'Lanes', detail: '9 parallel worktree lanes' }],
}

const R = {
  type: 'object',
  properties: {
    branch: { type: 'string' }, pr: { type: 'string' },
    fixed: { type: 'array', items: { type: 'string' } },
    deferred: { type: 'array', items: { type: 'string' } },
    verification: { type: 'string' }, notes: { type: 'string' },
  },
  required: ['branch', 'pr', 'fixed', 'deferred', 'verification', 'notes'],
}

const C = `
You are in an isolated git worktree of D:\\packages\\ball (HEAD=origin/main). Read repo-root CLAUDE.md first. Iron rules: fail loud; every fix needs a failing-before test (prefer conformance fixtures when encoder-reachable); NEVER edit generated files (regenerate: dart/shared/lib/gen/**, ts/engine/src/compiled_engine.ts, dart/shared/std.json, tests/snapshots via BALL_UPDATE_SNAPSHOTS=1); dart format touched Dart files; conformance regen produces CRLF-only churn — stage only real changes (git diff --ignore-cr-at-eol). WSL toolchain: wsl -e bash, build tree /mnt/d/packages/ball/cpp/build-wsl (g++14, cmake; ~10-15 min for compiler.cpp rebuilds — batch iterations).
Protocol: git checkout -b <branch>; implement; verify green; conventional commits with "fixes #NN"; push; gh pr create (body = fixes + verification), footer:
🤖 Generated with [Claude Code](https://claude.com/claude-code)
If an item balloons, defer it with a reason and land the rest. Return ONLY the structured result.`

phase('Lanes')
const [engine, covDart, covTs, covCpp, surface, protob, docs, snaps, setlit] = await parallel([

  () => agent(`${C}
LANE engine-bugs (branch fix/engine-bugs-wave3). You are the ONLY lane allowed to touch dart/engine or regenerate self-host artifacts. Fixtures: 355-369. Items IN ORDER:
1. #166 (gh issue view for full root-cause with line refs): implicit no-arg default constructors don't run an INHERITED field's own initializer when synthesizing __super__ — _buildSuperObject in dart/engine/lib/engine_eval.dart only copies fields the child resolved; reading such a field throws BallRuntimeError Field "X" not found. Fix + conformance fixture.
2. #167 (gh issue view): _evalReference (engine_eval.dart ~677) intercepts List/Map/Set names BEFORE scope.has(name), so a class field literally named List/Map/Set is unreadable (resolves to the builtin sentinel). Reorder the checks + fixture (a class with a field named 'List').
3. toStringAsExponential/Precision C++ byte-format parity (currently a documented carve-out in tests/conformance/ENCODER_COMPLETENESS_CARVEOUTS.md from PR #170): attempt byte-exact Dart formatting in the C++ compiler's emission (cpp/compiler/src/compiler.cpp — manual exponent normalization: minimal exponent digits, Dart trailing-zero rules; study Dart's actual output shapes via dart run first). If achieved, remove the carve-out entries + enable the fixtures on the C++ leg; if genuinely unreachable after a real attempt, keep the carve-out and say why precisely.
FINAL: regen engine.ball.json + compiled_engine.ts; if you touched cpp emission or runtime headers, regen tests/snapshots/cpp in WSL (BALL_UPDATE_SNAPSHOTS=1 test_snapshot, then verify-mode). Suites (report counts): dart/engine test; dart/compiler test -x slow; dart/encoder test + generate_conformance + both gates; Dart self-host parity (roundtrip_engine.dart tool then dart/self_host test — DO NOT SKIP); ts/engine npm test; ts/compiler npm test. Verify fixture shapes survive Dart->C++ lowering (plain statements, typed alias locals — see docs precedents).`,
    { label: 'lane:engine', phase: 'Lanes', isolation: 'worktree', agentType: 'general-purpose', model: 'opus', schema: R }),

  () => agent(`${C}
LANE cov-dart (branch cov/dart-wave3). Issue #61: raise Dart line coverage toward 100% (floor currently 91 in tools/coverage_dart.dart — read that tool first; it honors // coverage:ignore-* and excludes bin/ + generated files; it needs --exclude-tags slow per project convention). Measure per package (engine/encoder/compiler/shared/ball_protobuf/resolver/cli), find the largest uncovered clusters, and write tests — PREFER e2e conformance-style round-trips over unit tests (CLAUDE.md). Do NOT touch dart/engine SOURCE (test files only; another lane owns engine source). Ratchet the floor as high as it sustainably goes and update it in the tool/CI config. Verification: the coverage tool run with the new floor passes; all package suites green; dart format. Report before/after percentages per package.`,
    { label: 'lane:cov-dart', phase: 'Lanes', isolation: 'worktree', agentType: 'general-purpose', model: 'sonnet', schema: R }),

  () => agent(`${C}
LANE cov-ts (branch cov/ts-wave3). Issue #62: measure @ball-lang/{shared,compiler,engine,encoder} line coverage with c8 (add as devDependency where missing), excluding generated compiled_engine.ts and gen/. Write tests for the largest uncovered clusters (mirror existing suite styles; engine tests run the conformance corpus already — target the hand-written wrappers/setup/cli-adjacent code). Add a coverage floor script per package (npm run coverage with c8 check-coverage thresholds) and wire a CI step ONLY if a natural place exists in the TypeScript job (.github/workflows/ci.yml) — keep the CI edit minimal and isolated. Do NOT touch ts/engine/src/compiled_engine.ts or dart/. Verification: npm test + coverage thresholds green in all four packages; npx tsc --noEmit clean. Report before/after per package.`,
    { label: 'lane:cov-ts', phase: 'Lanes', isolation: 'worktree', agentType: 'general-purpose', model: 'sonnet', schema: R }),

  () => agent(`${C}
LANE cov-cpp (branch cov/cpp-wave3). Issue #63: measure cpp/{compiler,encoder,shared} line coverage (gcov/lcov via the WSL g++ tree: rebuild with --coverage flags into a SEPARATE build dir e.g. cpp/build-cov so build-wsl stays clean), excluding generated gen/ and dart/self_host/lib/engine_rt.cpp. Identify the largest uncovered clusters in hand-written code and add tests to cpp/test/*.cpp (the custom TEST macro framework — no gtest). Do NOT modify cpp/compiler or cpp/shared SOURCE (test files + build-config only; other lanes own source). If a floor/ratchet mechanism is feasible as a small script + optional CI step, add it minimally; otherwise report measurements + tests only. Verification: full cpp test suite green in WSL; report before/after coverage numbers per target.`,
    { label: 'lane:cov-cpp', phase: 'Lanes', isolation: 'worktree', agentType: 'general-purpose', model: 'sonnet', schema: R }),

  () => agent(`${C}
LANE conformance-surface (branch feat/conformance-surface). Issue #64, driven by DATA: read tests/conformance/std_coverage.json + STD_COVERAGE.md (generated inventory) and the gap report comment on issue #134 (gh issue view 134 --comments | tail). The 12 genuinely-uncovered base functions as of that report: double_to_string, int_to_string, is_not, label, length, list_all, list_any, list_concat, list_filter, list_insert, list_reverse, unsigned_right_shift. For each: determine if it is encoder-reachable from Dart source TODAY (check dart/encoder routing); if yes, write a conformance fixture (range 380-399) exercising it; if the route is missing but SMALL (a rename/alias in the encoder's routing tables), add the route + fixture; if it needs ENGINE changes, DEFER with a note (another lane owns engine). Rerun gen_std_coverage.dart and commit the updated inventory showing the uncovered count dropping. Verification: dart/encoder test + generate_conformance + completeness/fixture-name gates; dart/engine test; ts/engine npm test (fixtures must pass the TS self-host too); report uncovered-count before/after.`,
    { label: 'lane:surface', phase: 'Lanes', isolation: 'worktree', agentType: 'general-purpose', model: 'sonnet', schema: R }),

  () => agent(`${C}
LANE cpp-protobuf (branch feat/cpp-ball-protobuf). Issues #18 + #25 (gh issue view both — #18 has the task list): replace Google protobuf (CMake FetchContent, v34.1, ~90% of build time, abseil deadlock #25) with Ball's own compiled runtime cpp/shared/ball_protobuf_rt.cpp (3942 lines, exists) for the C++ compiler/encoder's Ball-IR loading, using nlohmann/json for the JSON parsing. Study first: how cpp/compiler+encoder currently consume protobuf (generated ball.pb.{h,cc}, DecodeProgram in ball_file.h), what ball_protobuf_rt.cpp exposes, and dart/compiler/tool/compile_ball_protobuf_cpp.dart. This is a LARGE change — a staged, honest partial landing is acceptable: e.g. land JSON-path loading via nlohmann + ball_protobuf_rt behind a CMake option with the old path still default, plus a CI-buildable proof target, and defer full cutover with precise notes. Do NOT break the existing build (all cpp tests must stay green in WSL). Do NOT touch cpp/compiler/src/compiler.cpp emission logic (other lanes own emission regions). Verification: WSL full cpp test suite + full_e2e.sh spot subset green with your changes; report exactly what stage landed vs deferred.`,
    { label: 'lane:cpp-protobuf', phase: 'Lanes', isolation: 'worktree', agentType: 'general-purpose', model: 'opus', schema: R }),

  () => agent(`${C}
LANE docs (branch docs/schema-and-article). Two items:
1. #133 (gh issue view for full spec): create ball.schema.json (JSON Schema Draft 2020-12) mirroring proto/ball/v1/ball.proto — spell out protobuf-JSON mapping rules explicitly (oneof = only-set-variant-key, int64-as-string, field name camelCase mapping, google.protobuf.Any envelope with @type, Struct/Value mapping) — plus docs/BALL_JSON_SPEC.md documenting the canonical Ball-JSON representation for JSON-only languages. VALIDATE the schema against real fixtures: write a small validation script (node with ajv or python jsonschema — whichever is installed; check first) and run it over ALL tests/conformance/*.ball.json — every fixture must validate; iterate the schema until they do. That validation run IS your test.
2. #136 (gh issue view): apply the editorial revisions to the 'Introducing Ball Language' article (find it under website/ or docs/) exactly as the issue specifies — no scope creep.
No code changes outside these deliverables. Verification: the fixture-validation run (N/N valid), plus any website build check if the article lives in website/ (jaspr build or the repo's documented check).`,
    { label: 'lane:docs', phase: 'Lanes', isolation: 'worktree', agentType: 'general-purpose', model: 'sonnet', schema: R }),

  () => agent(`${C}
LANE snapshots (branch feat/snapshot-preamble-strip). Issue #147 (gh issue view): stop pinning the ~240KB spliced runtime preamble in every tests/snapshots/cpp/*.snapshot.cpp (37 x ~247KB, churns wholesale on any runtime edit). Implement the issue's proposal: the C++ compiler emits a stable marker comment right after the runtime splice (find the splice in compiler.cpp ~emit of BALL_EMIT_RUNTIME_SOURCE/BALL_DYN_SOURCE; add e.g. "// === BALL EMITTED PROGRAM ==="), and cpp/test/test_snapshot.cpp strips everything up to+including the marker before comparing/writing. Regenerate all snapshots (WSL: BALL_UPDATE_SNAPSHOTS=1 test_snapshot, then verify-mode 37/37) — they should shrink from ~247KB to the program tail. NOTE conflicts: other lanes may also touch compiler.cpp (different regions) and snapshots — at the END, rebase onto origin/main, re-regen snapshots, re-verify before push. Also update .gitattributes/docs references if any mention snapshot sizes. Verification: test_snapshot 37/37 both modes; a runtime-header no-op touch no longer changes any snapshot (prove it: add/remove a comment line in ball_dyn.h, regen, git diff empty on snapshots, revert the comment).`,
    { label: 'lane:snapshots', phase: 'Lanes', isolation: 'worktree', agentType: 'general-purpose', model: 'sonnet', schema: R }),

  () => agent(`${C}
LANE cpp-set-literals (branch fix/cpp-set-literals). Issue #174 (gh issue view — full spec): the direct-compile C++ path has no set-literal semantics; print({1,2,3}) renders [1, 2, 3] and duplicates survive. Implement per the issue: emit set literals as the portable one-key {'__ball_set__': [...]} map (the SAME representation the engine uses since #68 — read how dart/engine represents/renders it) with insertion-ordered dedup on construction; special-case that key in BallDyn's map rendering (ball_dyn.h string conversion) to Dart-style {a, b, c}; confirm is Set (ball_is_ball_set — already wired), .contains/.add/.length and set ops route correctly for directly-compiled programs. Oracle: fixture 350_set_value must byte-match on the compiled-C++ path (WSL: compile with the rebuilt ball_cpp_compile, g++, run, diff), and 118/129/237/310 must STAY matching. You will likely touch ball_dyn.h => regen tests/snapshots/cpp (BALL_UPDATE_SNAPSHOTS=1, verify 37/37) — and NOTE: lane 'snapshots' is changing the snapshot FORMAT concurrently; at the END rebase onto origin/main and re-regen before push. Add unit tests in cpp/test/test_compiler.cpp for the set-literal emission. Verification: fixture matrix results + test_compiler suite count.`,
    { label: 'lane:set-literals', phase: 'Lanes', isolation: 'worktree', agentType: 'general-purpose', model: 'sonnet', schema: R }),
])

return {
  engine: engine ?? {notes:'died'}, covDart: covDart ?? {notes:'died'}, covTs: covTs ?? {notes:'died'},
  covCpp: covCpp ?? {notes:'died'}, surface: surface ?? {notes:'died'}, cppProtobuf: protob ?? {notes:'died'},
  docs: docs ?? {notes:'died'}, snapshots: snaps ?? {notes:'died'}, setLiterals: setlit ?? {notes:'died'},
}