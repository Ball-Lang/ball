#!/usr/bin/env node
/**
 * ball-ts-compile — Ball (binary .ball.pb or proto3 JSON) → TypeScript.
 *
 * Usage:
 *   ball-ts-compile <program.ball.json|program.ball.pb> [--out <path>] [--no-preamble]
 *
 * If --out is omitted, writes to stdout.
 * If the input file doesn't match either extension, JSON is assumed.
 */
import { readFileSync, writeFileSync } from "node:fs";
import { extname } from "node:path";
import { compile } from "../dist/index.js";

function die(msg) {
  process.stderr.write(`ball-ts-compile: ${msg}\n`);
  process.exit(1);
}

function parseArgs(argv) {
  const out = { input: null, output: null, includePreamble: true };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--out" && i + 1 < argv.length) { out.output = argv[++i]; }
    else if (a === "--no-preamble") { out.includePreamble = false; }
    else if (a === "-h" || a === "--help") {
      process.stdout.write(
        "Usage: ball-ts-compile <program.ball.json|program.ball.pb> [--out <path>] [--no-preamble]\n"
      );
      process.exit(0);
    }
    else if (!out.input) { out.input = a; }
    else { die(`unexpected argument: ${a}`); }
  }
  if (!out.input) die("missing input file");
  return out;
}

const args = parseArgs(process.argv.slice(2));
const ext = extname(args.input).toLowerCase();

// Ball files are self-describing google.protobuf.Any envelopes; strip the
// "@type" key (if present) to recover the bare proto3-JSON Program.
function unwrapBallFile(json) {
  if (json === null || typeof json !== "object" || Array.isArray(json)) return json;
  const type = json["@type"];
  if (type === undefined) return json;
  const ok = typeof type === "string" &&
    (type.endsWith("/ball.v1.Program") || type.endsWith("/ball.v1.Module"));
  if (!ok) die(`unknown ball file @type: ${JSON.stringify(type)}`);
  const body = {};
  for (const [k, v] of Object.entries(json)) { if (k !== "@type") body[k] = v; }
  return body;
}

let program;
if (ext === ".pb") {
  die("binary .ball.pb not yet supported in @ball-lang/compiler (use .ball.json)");
} else {
  const text = readFileSync(args.input, "utf8");
  try { program = JSON.parse(text); }
  catch (e) { die(`invalid JSON: ${e.message}`); }
  program = unwrapBallFile(program);
}

const ts = compile(program, { includePreamble: args.includePreamble });
if (args.output) {
  writeFileSync(args.output, ts);
} else {
  process.stdout.write(ts);
}
