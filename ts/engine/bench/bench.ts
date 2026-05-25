/**
 * Repeatable micro-benchmark for the compiled Ball TS engine.
 *
 * Measures median wall-clock of running compute-heavy conformance fixtures
 * through the compiled (self-hosted) engine. The engine's own AST traversal
 * (whichExpr/hasBody/.entries/.length/etc.) is what's being stressed — the
 * fixture programs are small, so the cost is dominated by per-node engine
 * dispatch, not the program's arithmetic.
 *
 * Run: node --experimental-strip-types bench/bench.ts
 *      node --experimental-strip-types bench/bench.ts --iters 80 --warmup 15
 */
import { readFileSync } from 'fs';
import { join } from 'path';
import { BallEngine } from '../src/index.ts';

function arg(flag: string, def: number): number {
  const i = process.argv.indexOf(flag);
  return i >= 0 && process.argv[i + 1] ? Number(process.argv[i + 1]) : def;
}

const ITERS = arg('--iters', 60);
const WARMUP = arg('--warmup', 12);

const conformanceDir = join(import.meta.dirname ?? '.', '../../../tests/conformance');
const FIXTURES = ['28_fibonacci', '132_merge_sort', '137_pascals_triangle'];

function median(xs: number[]): number {
  const s = [...xs].sort((a, b) => a - b);
  const m = Math.floor(s.length / 2);
  return s.length % 2 ? s[m] : (s[m - 1] + s[m]) / 2;
}

async function timeOne(programJson: string): Promise<number> {
  const t0 = performance.now();
  const engine = new BallEngine(programJson);
  await engine.run();
  // touch output so the call isn't dead-code-eliminated
  if (engine.getOutput().length < 0) throw new Error('unreachable');
  return performance.now() - t0;
}

async function benchFixture(name: string): Promise<{ name: string; median: number; min: number; runs: number }> {
  const programJson = readFileSync(join(conformanceDir, `${name}.ball.json`), 'utf-8');
  for (let i = 0; i < WARMUP; i++) await timeOne(programJson);
  const samples: number[] = [];
  for (let i = 0; i < ITERS; i++) samples.push(await timeOne(programJson));
  return { name, median: median(samples), min: Math.min(...samples), runs: ITERS };
}

async function main() {
  console.log(`Ball TS engine benchmark — iters=${ITERS} warmup=${WARMUP} node=${process.version}`);
  console.log('fixture                       median(ms)   min(ms)');
  console.log('--------------------------------------------------');
  let total = 0;
  for (const f of FIXTURES) {
    const r = await benchFixture(f);
    total += r.median;
    console.log(`${r.name.padEnd(28)}  ${r.median.toFixed(3).padStart(9)}  ${r.min.toFixed(3).padStart(8)}`);
  }
  console.log('--------------------------------------------------');
  console.log(`${'TOTAL median'.padEnd(28)}  ${total.toFixed(3).padStart(9)}`);
}

main();
