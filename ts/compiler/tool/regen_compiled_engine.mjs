#!/usr/bin/env node --experimental-strip-types
/**
 * Regenerate `ts/engine/src/compiled_engine.ts` — the TypeScript self-hosted
 * engine — by compiling `dart/self_host/engine.ball.json` through this package.
 *
 *   cd ts/compiler && node --experimental-strip-types tool/regen_compiled_engine.mjs
 *
 * This is the TS sibling of `cargo run -p ball-engine-regen` (Rust),
 * `dotnet run --project engine/tool/Ball.Engine.Regen.csproj` (C#),
 * `go run ./cmd/regen` (Go) and `python -m ball_engine.regen` (Python). Unlike
 * all of those, ts/engine/src/compiled_engine.ts is COMMITTED, so it is the one
 * compiled engine that can go stale in git — ci.yml's `Ball Artifact Freshness`
 * job runs this script and diffs the result.
 *
 * `dart/self_host/engine.ball.json` is itself generated (and gitignored);
 * regenerate it first with `cd dart && dart run compiler/tool/gen_engine_json.dart`.
 */
import { readFileSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";
import { compile } from "../src/index.ts";

const here = dirname(fileURLToPath(import.meta.url));
const inputPath = resolve(here, "../../../dart/self_host/engine.ball.json");
const outputPath = resolve(here, "../../engine/src/compiled_engine.ts");

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
    `regen_compiled_engine: cannot read ${inputPath}: ${err.message}\n` +
      "Generate it first with: cd dart && dart run compiler/tool/gen_engine_json.dart\n",
  );
  process.exit(1);
}

const program = unwrapBallFile(JSON.parse(raw));
const payload = "// @ts-nocheck — auto-generated\n" + compile(program);
writeFileSync(outputPath, payload);
// Byte count, not `payload.length`: String.length counts UTF-16 code units and
// the emitted engine is full of non-ASCII, so the two disagree by hundreds of
// bytes. Report the number `stat -c%s` / `ls -l` will show.
process.stdout.write(
  `regen_compiled_engine: wrote ${Buffer.byteLength(payload, "utf8")} bytes → ${outputPath}\n`,
);
