#!/usr/bin/env node --experimental-strip-types
/**
 * Regenerate `ts/cli/src/compiled_cli.ts` — the TypeScript self-hosted CLI core
 * (`ball info` / `validate` / `tree` / `version` / `audit`, issue #364) — by
 * compiling `dart/self_host/cli.ball.json` through this package.
 *
 *   cd ts/compiler && node --experimental-strip-types tool/regen_compiled_cli.mjs
 *
 * Same pipeline as the sibling `regen_compiled_engine.mjs`, plus an
 * export-rewrite pass: `cli_core.dart` is a free-function library (not a single
 * class like `engine.dart`), so its compiled top-level declarations need
 * `export` added explicitly — `BallCompiler.compile()`'s own export logic only
 * covers top-level *classes*.
 *
 * `ts/cli/src/compiled_cli.ts` is COMMITTED (like `compiled_engine.ts`, unlike
 * the Rust/C#/Go/Python compiled CLI cores, which are gitignored and rebuilt
 * inside their own jobs), so it is one of only two compiled artifacts that can
 * go stale in git — ci.yml's `Ball Artifact Freshness` job runs this script and
 * diffs the result (issue #580).
 *
 * `dart/self_host/cli.ball.json` is itself generated (and gitignored);
 * regenerate it first with `cd dart && dart run compiler/tool/gen_cli_json.dart`.
 */
import { readFileSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";
import { compile } from "../src/index.ts";

const here = dirname(fileURLToPath(import.meta.url));
const inputPath = resolve(here, "../../../dart/self_host/cli.ball.json");
const outputPath = resolve(here, "../../cli/src/compiled_cli.ts");

/**
 * A `.ball.json` file is a self-describing `google.protobuf.Any` envelope
 * (`{"@type": "…/ball.v1.Program", …}`); the compiler wants the bare Program.
 */
function unwrapBallFile(json) {
  if (json === null || typeof json !== "object" || Array.isArray(json)) return json;
  if (json["@type"] === undefined) return json;
  const bare = {};
  for (const [k, v] of Object.entries(json)) {
    if (k !== "@type") bare[k] = v;
  }
  return bare;
}

let raw;
try {
  raw = readFileSync(inputPath, "utf8");
} catch (err) {
  process.stderr.write(
    `regen_compiled_cli: cannot read ${inputPath}: ${err.message}\n` +
      "Generate it first with: cd dart && dart run compiler/tool/gen_cli_json.dart\n",
  );
  process.exit(1);
}

const program = unwrapBallFile(JSON.parse(raw));

let ts = compile(program);
ts = ts.replace(/^(function )/gm, "export $1");
ts = ts.replace(/^(class )/gm, "export $1");
ts = ts.replace(/^(enum )/gm, "export $1");
ts = ts.replace(/^(let )/gm, "export $1");
ts = ts.replace(/^(const )/gm, "export $1");
ts = ts.replace(/^export export /gm, "export ");

const payload = "// @ts-nocheck — auto-generated\n" + ts;
writeFileSync(outputPath, payload);
// Byte count, not `payload.length`: String.length counts UTF-16 code units and
// the emitted CLI core is full of non-ASCII, so the two disagree by hundreds of
// bytes. Report the number `stat -c%s` / `ls -l` will show.
process.stdout.write(
  `regen_compiled_cli: wrote ${Buffer.byteLength(payload, "utf8")} bytes → ${outputPath}\n`,
);
