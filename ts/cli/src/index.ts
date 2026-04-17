#!/usr/bin/env node
/**
 * Ball CLI — command-line interface for the Ball programming language.
 *
 * Commands:
 *   ball run <program.ball.json>               Execute a Ball program.
 *   ball audit <program.ball.json>             Static capability analysis.
 *   ball --version                             Print version.
 *   ball --help                                Print usage.
 */

import { readFileSync, writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { BallEngine } from '@ball-lang/engine';
import {
  analyzeCapabilities,
  checkPolicy,
  formatCapabilityReport,
  type Program,
} from './capability_analyzer.ts';

const VERSION = readVersion();

const USAGE = `ball — the Ball language CLI (v${VERSION})

USAGE
  ball <command> [options]

COMMANDS
  run <program.ball.json>        Execute a Ball program and print stdout.
  audit <program.ball.json>      Static capability analysis (I/O, fs, network, ...).

OPTIONS
  -h, --help                     Print this help message.
  -v, --version                  Print version information.

AUDIT OPTIONS
  --output <path>                Write the JSON report to <path>.
  --deny <caps>                  Comma-separated capabilities to deny
                                 (e.g. 'fs,network,process'). Exit 1 on violation.
  --reachable-only               Only analyze functions reachable from the entry.
  --json                         Emit JSON report to stdout (instead of text).

EXAMPLES
  ball run examples/hello_world/hello_world.ball.json
  ball audit my_program.ball.json
  ball audit my_program.ball.json --deny fs,network
  ball audit my_program.ball.json --output report.json --json
`;

type ParsedArgs = {
  command?: string;
  positional: string[];
  flags: Record<string, string | true>;
};

function parseArgs(argv: string[]): ParsedArgs {
  const flags: Record<string, string | true> = {};
  const positional: string[] = [];
  let command: string | undefined;

  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i]!;

    if (arg === '--') {
      for (let j = i + 1; j < argv.length; j++) positional.push(argv[j]!);
      break;
    }

    if (arg.startsWith('--')) {
      const eq = arg.indexOf('=');
      if (eq >= 0) {
        const key = arg.substring(2, eq);
        flags[key] = arg.substring(eq + 1);
      } else {
        const key = arg.substring(2);
        const next = argv[i + 1];
        if (next !== undefined && !next.startsWith('-')) {
          flags[key] = next;
          i++;
        } else {
          flags[key] = true;
        }
      }
      continue;
    }

    if (arg.startsWith('-') && arg.length > 1) {
      const short = arg.substring(1);
      flags[short] = true;
      continue;
    }

    if (command === undefined) {
      command = arg;
    } else {
      positional.push(arg);
    }
  }

  return { command, positional, flags };
}

function readVersion(): string {
  // package.json lives one directory up from either dist/ or src/.
  try {
    const here = dirname(fileURLToPath(import.meta.url));
    const pkgPath = join(here, '..', 'package.json');
    const pkg = JSON.parse(readFileSync(pkgPath, 'utf8')) as { version?: string };
    if (typeof pkg.version === 'string') return pkg.version;
  } catch {
    // Fallthrough.
  }
  return '0.0.0';
}

function loadProgram(path: string): Program {
  let raw: string;
  try {
    raw = readFileSync(path, 'utf8');
  } catch (e) {
    const err = e as NodeJS.ErrnoException;
    if (err.code === 'ENOENT') {
      fail(`File not found: ${path}`);
    }
    fail(`Could not read ${path}: ${err.message}`);
  }
  try {
    return JSON.parse(raw) as Program;
  } catch (e) {
    const err = e as Error;
    fail(`Invalid JSON in ${path}: ${err.message}`);
  }
}

function fail(message: string): never {
  process.stderr.write(`ball: ${message}\n`);
  process.exit(1);
}

function cmdRun(args: ParsedArgs): number {
  const programPath = args.positional[0];
  if (!programPath) {
    process.stderr.write('ball: run requires a program path\n\n');
    process.stderr.write(USAGE);
    return 1;
  }

  const program = loadProgram(programPath);
  const engine = new BallEngine(program as any, {
    stdout: (msg: string) => process.stdout.write(msg + '\n'),
    stderr: (msg: string) => process.stderr.write(msg + '\n'),
  });

  try {
    engine.run();
  } catch (e) {
    const err = e as Error;
    fail(`runtime error: ${err.message}`);
  }
  return 0;
}

function cmdAudit(args: ParsedArgs): number {
  const programPath = args.positional[0];
  if (!programPath) {
    process.stderr.write('ball: audit requires a program path\n\n');
    process.stderr.write(USAGE);
    return 1;
  }

  const program = loadProgram(programPath);
  const reachableOnly = args.flags['reachable-only'] === true;
  const report = analyzeCapabilities(program, { reachableOnly });

  const denyRaw = args.flags['deny'];
  const denySet =
    typeof denyRaw === 'string'
      ? new Set(
          denyRaw
            .split(',')
            .map((c) => c.trim())
            .filter((c) => c.length > 0),
        )
      : new Set<string>();

  const outputPath = args.flags['output'];
  if (typeof outputPath === 'string') {
    try {
      writeFileSync(outputPath, JSON.stringify(report, null, 2) + '\n');
    } catch (e) {
      const err = e as Error;
      fail(`could not write ${outputPath}: ${err.message}`);
    }
  }

  const asJson = args.flags['json'] === true;
  if (asJson) {
    process.stdout.write(JSON.stringify(report, null, 2) + '\n');
  } else {
    process.stdout.write(formatCapabilityReport(report));
  }

  if (denySet.size > 0) {
    const violations = checkPolicy(report, denySet);
    if (violations.length > 0) {
      process.stderr.write('\nPolicy violations:\n');
      for (const v of violations) process.stderr.write(`  - ${v}\n`);
      return 1;
    }
  }

  return 0;
}

function main(argv: string[]): number {
  const args = parseArgs(argv);

  if (args.flags['help'] === true || args.flags['h'] === true) {
    process.stdout.write(USAGE);
    return 0;
  }

  if (args.flags['version'] === true || args.flags['v'] === true) {
    process.stdout.write(`${VERSION}\n`);
    return 0;
  }

  switch (args.command) {
    case 'run':
      return cmdRun(args);
    case 'audit':
      return cmdAudit(args);
    case undefined:
      process.stdout.write(USAGE);
      return 0;
    default:
      process.stderr.write(`ball: unknown command '${args.command}'\n\n`);
      process.stderr.write(USAGE);
      return 1;
  }
}

process.exit(main(process.argv.slice(2)));
