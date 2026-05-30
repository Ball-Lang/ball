// Minimal harness: instantiate the compiled engine directly, no wrapper.
// Used to diagnose what's missing from the Ball -> TS compile so we can
// drive the encoder/compiler to emit a self-sufficient engine.
import { BallEngine } from '../src/compiled_engine.ts';
import { readFileSync } from 'node:fs';

const path = process.argv[2];
if (!path) {
  console.error('usage: node harness_pure.mjs <fixture.ball.json>');
  process.exit(2);
}

// Ball files are self-describing google.protobuf.Any envelopes; strip "@type".
function unwrapBallFile(json) {
  if (json === null || typeof json !== 'object' || Array.isArray(json)) return json;
  const type = json['@type'];
  if (type === undefined) return json;
  const body = {};
  for (const [k, v] of Object.entries(json)) { if (k !== '@type') body[k] = v; }
  return body;
}

const program = unwrapBallFile(JSON.parse(readFileSync(path, 'utf8')));
const out = [];
const engine = new BallEngine(
  program,
  (msg) => out.push(msg),
  (msg) => process.stderr.write(msg + '\n'),
  null,
  null,
  [],
  false,
  10000,
  null,
  null,
  100,
  1000,
  10 * 1024 * 1024,
  false,
  null,
  null,
);
try {
  await engine.run();
} catch (e) {
  console.error('ENGINE_ERROR:', e);
  console.error('STACK:', e?.stack);
  process.exit(1);
}
process.stdout.write(out.join('\n'));
if (out.length > 0) process.stdout.write('\n');
