/**
 * TypeScript wrapper around the compiled cli-core verbs — `info`, `validate`,
 * `tree`, `version` (issue #364).
 *
 * `compiled_cli.ts` is auto-generated (see its own file header for the regen
 * recipe) by compiling `dart/self_host/cli.ball.json` through
 * `@ball-lang/compiler` — the same pipeline `ts/engine/src/compiled_engine.ts`
 * uses for the self-hosted engine. Its `infoReport` / `validateReport` /
 * `validateOk` / `treeReport` / `versionLine` functions are a straight
 * compile of `dart/shared/lib/cli_core.dart`'s pure `Program -> String`
 * verbs, so this wrapper's only job is bridging representations:
 *
 *   - The compiled functions access proto3-JSON fields via **direct property
 *     access with no optional chaining** (e.g. `program.modules.length`,
 *     `imp.http.url`) — the same assumption the Dart *tree-walking engine*
 *     makes about its input (see the self-host parity gate at
 *     `dart/cli/test/cli_core_parity_test.dart`, whose `protoToEngineMap`
 *     helper performs the equivalent normalization on the Dart side).
 *   - Real `.ball.json` files are proto3 JSON, which **omits** default/empty
 *     fields (`modules: []`, an unset `entryModule: ""`, an absent
 *     `moduleImports`). Fed directly to the compiled functions, a missing
 *     repeated field throws ("Cannot read properties of undefined").
 *   - `normalizeProgram` below fully materializes every field the four verbs
 *     touch (Program / Module / FunctionDefinition / ModuleImport + its five
 *     `source` variants) with its proto3 default — mirroring
 *     `protoToEngineMap`'s job for the TS side. It's intentionally scoped to
 *     exactly cli_core's field surface (not a generic protobuf normalizer),
 *     kept in this small wrapper (not `engine_setup.ts`'s much larger,
 *     generic `protoWrap`) because `@ball-lang/cli` has no dependency path to
 *     `@ball-lang/engine`'s internal `engine_setup.ts` (it isn't part of that
 *     package's public `exports` map) — see `dart/cli/AGENTS.md` /
 *     `ts/cli/AGENTS.md` for the parity gate this feeds.
 *
 * Regenerate `compiled_cli.ts` whenever `dart/shared/lib/cli_core.dart`
 * changes — see CLAUDE.md's "Regenerate compiled TS CLI core" recipe.
 */

import {
  infoReport as _infoReport,
  validateReport as _validateReport,
  validateOk as _validateOk,
  treeReport as _treeReport,
  versionLine as _versionLine,
} from './compiled_cli.ts';

// ── Ball program types (proto3 JSON shape) ──────────────────────────────────
// Intentionally permissive and redeclared locally — same convention as
// `capability_analyzer.ts` — so this wrapper has no hard dependency on the
// engine's private types, only the fields the four verbs actually read.

export interface Program {
  name?: string;
  version?: string;
  entryModule?: string;
  entryFunction?: string;
  modules?: ProgramModule[];
}

export interface ProgramModule {
  name?: string;
  description?: string;
  functions?: ProgramFunction[];
  typeDefs?: unknown[];
  typeAliases?: unknown[];
  enums?: unknown[];
  moduleImports?: ModuleImport[];
}

export interface ProgramFunction {
  name?: string;
  isBase?: boolean;
  body?: unknown;
  metadata?: unknown;
}

export interface ModuleImport {
  name?: string;
  http?: { url?: string };
  file?: { path?: string };
  git?: { url?: string; ref?: string };
  registry?: { package?: string; version?: string; registry?: string };
  inline?: unknown;
}

// ── normalization ────────────────────────────────────────────────────────────

function normalizeFunction(raw: ProgramFunction): unknown {
  const out: Record<string, unknown> = { name: raw.name ?? '', isBase: raw.isBase ?? false };
  // hasBody()/hasMetadata() (compiled as free functions routed through the
  // ball_proto base module) treat undefined/null as "absent" — so these two
  // are only copied across when actually set, never defaulted to a sentinel.
  if (raw.body !== undefined) out.body = raw.body;
  if (raw.metadata !== undefined) out.metadata = raw.metadata;
  return out;
}

function normalizeModuleImport(raw: ModuleImport): unknown {
  const out: Record<string, unknown> = { name: raw.name ?? '' };
  if (raw.http) out.http = { url: raw.http.url ?? '' };
  if (raw.file) out.file = { path: raw.file.path ?? '' };
  if (raw.git) out.git = { url: raw.git.url ?? '', ref: raw.git.ref ?? '' };
  if (raw.registry) {
    // RegistrySource.registry is a `Registry` enum; Dart's generated
    // accessor exposes it as `imp.registry.registry.name` (the enum's own
    // string name). Proto3 JSON already encodes an enum field AS its name
    // string, so wrap it in a `{name}` object here to match what
    // cli_core.dart's `_importSource` — compiled 1:1 into `compiled_cli.ts`
    // — expects at that property-access site.
    out.registry = {
      package: raw.registry.package ?? '',
      version: raw.registry.version ?? '',
      registry: { name: raw.registry.registry ?? 'REGISTRY_UNSPECIFIED' },
    };
  }
  if (raw.inline) out.inline = {};
  return out;
}

function normalizeModule(raw: ProgramModule): unknown {
  return {
    name: raw.name ?? '',
    description: raw.description ?? '',
    functions: (raw.functions ?? []).map(normalizeFunction),
    typeDefs: raw.typeDefs ?? [],
    typeAliases: raw.typeAliases ?? [],
    enums: raw.enums ?? [],
    moduleImports: (raw.moduleImports ?? []).map(normalizeModuleImport),
  };
}

/**
 * Fully materialize a proto3-JSON `Program` (with omitted defaults) into the
 * shape `compiled_cli.ts`'s verbs expect (every touched field present).
 * Exported so the parity test can normalize once and feed the identical
 * value to the compiled verb under test.
 */
export function normalizeProgram(raw: Program): unknown {
  return {
    name: raw.name ?? '',
    version: raw.version ?? '',
    entryModule: raw.entryModule ?? '',
    entryFunction: raw.entryFunction ?? '',
    modules: (raw.modules ?? []).map(normalizeModule),
  };
}

// ── public verbs ─────────────────────────────────────────────────────────────
// Mirror `dart/shared/lib/cli_core.dart`'s public API 1:1 (same names, same
// String/bool results) — operating on the compiled Ball IR instead of native
// Dart, so the two implementations are provably the same computation over the
// same input (see `test/cli_core_parity_test.ts`).

export function infoReport(program: Program): string {
  return _infoReport(normalizeProgram(program)) as string;
}

export function validateReport(program: Program): string {
  return _validateReport(normalizeProgram(program)) as string;
}

export function validateOk(program: Program): boolean {
  return _validateOk(normalizeProgram(program)) as boolean;
}

export function treeReport(program: Program): string {
  return _treeReport(normalizeProgram(program)) as string;
}

export function versionLine(version: string): string {
  return _versionLine(version) as string;
}
