/**
 * Static capability analysis for Ball programs.
 *
 * Walks the expression tree of every function in a Program and reports
 * which base functions are called, categorized by side-effect capability.
 * Since every side effect in Ball flows through a named base function,
 * this analysis is provably complete — not heuristic.
 *
 * Ported from `dart/shared/lib/capability_analyzer.dart`.
 */

import {
  ALL_CAPABILITIES,
  capabilityRiskLevel,
  lookupCapability,
} from './capability_table.ts';
import type { Capability } from './capability_table.ts';

// ── Ball program types (proto3 JSON shape) ──────────────────────────────────
// Intentionally permissive — these mirror the JSON structure of a Ball
// program. They match the engine's internal types but are redeclared here so
// the analyzer has no hard dependency on the engine's private types.

export interface Program {
  name?: string;
  version?: string;
  modules: Module[];
  entryModule: string;
  entryFunction: string;
}

export interface Module {
  name: string;
  functions: FunctionDef[];
}

export interface FunctionDef {
  name: string;
  isBase?: boolean;
  body?: Expression;
}

export interface Expression {
  call?: FunctionCall;
  literal?: Literal;
  reference?: { name: string };
  fieldAccess?: { object?: Expression; field: string };
  messageCreation?: { fields: FieldValuePair[] };
  block?: Block;
  lambda?: Lambda;
}

export interface FunctionCall {
  module?: string;
  function: string;
  input?: Expression;
}

export interface Literal {
  listValue?: { elements: Expression[] };
  // Other literal variants ignored — they contain no sub-expressions.
}

export interface FieldValuePair {
  name: string;
  value: Expression;
}

export interface Block {
  statements: Statement[];
  result?: Expression;
}

export interface Statement {
  let?: { name: string; value: Expression };
  expression?: Expression;
}

export interface Lambda {
  body: Expression;
}

// ── Report types ────────────────────────────────────────────────────────────

export interface CallSite {
  module: string;
  function: string;
  calleeModule: string;
  calleeFunction: string;
}

export interface FunctionCapability {
  module: string;
  function: string;
  capabilities: Capability[];
}

export interface CapabilityEntry {
  capability: Capability;
  riskLevel: string;
  callSites: CallSite[];
}

export interface CapabilitySummary {
  isPure: boolean;
  readsFilesystem: boolean;
  writesFilesystem: boolean;
  readsStdin: boolean;
  writesStdout: boolean;
  writesStderr: boolean;
  readsEnvironment: boolean;
  controlsProcess: boolean;
  usesMemory: boolean;
  usesTime: boolean;
  usesRandom: boolean;
  usesConcurrency: boolean;
  usesNetwork: boolean;
  totalFunctions: number;
  pureFunctions: number;
  effectfulFunctions: number;
}

export interface BallCapabilityReport {
  programName: string;
  programVersion: string;
  capabilities: CapabilityEntry[];
  functions: FunctionCapability[];
  summary: CapabilitySummary;
}

// ── Analyzer ────────────────────────────────────────────────────────────────

export interface AnalyzeOptions {
  /** If true, only analyze functions transitively reachable from the entry. */
  reachableOnly?: boolean;
}

/** Analyze a Ball program and return a structured capability report. */
export function analyzeCapabilities(
  program: Program,
  options: AnalyzeOptions = {},
): BallCapabilityReport {
  return new Analyzer(program, options.reachableOnly ?? false).analyze();
}

class Analyzer {
  private readonly program: Program;
  private readonly reachableOnly: boolean;
  private readonly fnCaps = new Map<string, Set<Capability>>();
  private readonly capCallSites = new Map<Capability, CallSite[]>();
  private readonly baseModules = new Set<string>();

  constructor(program: Program, reachableOnly: boolean) {
    this.program = program;
    this.reachableOnly = reachableOnly;
  }

  analyze(): BallCapabilityReport {
    this.identifyBaseModules();
    if (this.reachableOnly) {
      this.analyzeReachable();
    } else {
      this.analyzeAll();
    }
    return this.buildReport();
  }

  private identifyBaseModules(): void {
    for (const mod of this.program.modules) {
      if (mod.functions.length === 0) continue;
      const allBase = mod.functions.every((f) => f.isBase === true);
      if (allBase) this.baseModules.add(mod.name);
    }
  }

  private analyzeAll(): void {
    for (const mod of this.program.modules) {
      if (this.baseModules.has(mod.name)) continue;
      for (const fn of mod.functions) {
        if (fn.isBase) continue;
        const caps = new Set<Capability>();
        if (fn.body) this.walkExpression(fn.body, mod.name, fn.name, caps);
        this.fnCaps.set(`${mod.name}.${fn.name}`, caps);
      }
    }
  }

  private analyzeReachable(): void {
    const visited = new Set<string>();
    const entryKey = `${this.program.entryModule}.${this.program.entryFunction}`;
    this.analyzeFunction(entryKey, visited);
  }

  private analyzeFunction(key: string, visited: Set<string>): void {
    if (visited.has(key)) return;
    visited.add(key);

    const parts = key.split('.');
    if (parts.length < 2) return;
    const moduleName = parts[0]!;
    const fnName = parts.slice(1).join('.');

    if (this.baseModules.has(moduleName)) return;

    for (const mod of this.program.modules) {
      if (mod.name !== moduleName) continue;
      for (const fn of mod.functions) {
        if (fn.name !== fnName) continue;
        if (fn.isBase) return;
        const caps = new Set<Capability>();
        const callees = new Set<string>();
        if (fn.body) {
          this.walkExpression(fn.body, moduleName, fnName, caps, callees);
        }
        this.fnCaps.set(key, caps);
        for (const callee of callees) {
          this.analyzeFunction(callee, visited);
          const calleeCaps = this.fnCaps.get(callee);
          if (calleeCaps) for (const c of calleeCaps) caps.add(c);
        }
        return;
      }
    }
  }

  private walkExpression(
    expr: Expression,
    ctxModule: string,
    ctxFunction: string,
    caps: Set<Capability>,
    callees?: Set<string>,
  ): void {
    if (expr.call) {
      this.walkCall(expr.call, ctxModule, ctxFunction, caps, callees);
      return;
    }
    if (expr.literal) {
      if (expr.literal.listValue) {
        for (const elem of expr.literal.listValue.elements) {
          this.walkExpression(elem, ctxModule, ctxFunction, caps, callees);
        }
      }
      return;
    }
    if (expr.block) {
      for (const stmt of expr.block.statements) {
        if (stmt.let) {
          this.walkExpression(stmt.let.value, ctxModule, ctxFunction, caps, callees);
        }
        if (stmt.expression) {
          this.walkExpression(stmt.expression, ctxModule, ctxFunction, caps, callees);
        }
      }
      if (expr.block.result) {
        this.walkExpression(expr.block.result, ctxModule, ctxFunction, caps, callees);
      }
      return;
    }
    if (expr.lambda) {
      this.walkExpression(expr.lambda.body, ctxModule, ctxFunction, caps, callees);
      return;
    }
    if (expr.messageCreation) {
      for (const field of expr.messageCreation.fields) {
        this.walkExpression(field.value, ctxModule, ctxFunction, caps, callees);
      }
      return;
    }
    if (expr.fieldAccess?.object) {
      this.walkExpression(expr.fieldAccess.object, ctxModule, ctxFunction, caps, callees);
      return;
    }
    // reference or unset: nothing to walk
  }

  private walkCall(
    call: FunctionCall,
    ctxModule: string,
    ctxFunction: string,
    caps: Set<Capability>,
    callees?: Set<string>,
  ): void {
    const moduleName = call.module && call.module.length > 0 ? call.module : ctxModule;
    const fnName = call.function;

    const cap = lookupCapability(moduleName, fnName);
    if (cap !== undefined) {
      caps.add(cap);
      if (cap !== 'pure') {
        const list = this.capCallSites.get(cap) ?? [];
        list.push({
          module: ctxModule,
          function: ctxFunction,
          calleeModule: moduleName,
          calleeFunction: fnName,
        });
        this.capCallSites.set(cap, list);
      }
    } else {
      callees?.add(`${moduleName}.${fnName}`);
    }

    if (call.input) {
      this.walkExpression(call.input, ctxModule, ctxFunction, caps, callees);
    }
  }

  private buildReport(): BallCapabilityReport {
    const allCaps = new Set<Capability>();
    let totalFns = 0;
    let pureFns = 0;
    let effectfulFns = 0;

    const functions: FunctionCapability[] = [];

    for (const [key, caps] of this.fnCaps) {
      const dot = key.indexOf('.');
      const mod = key.substring(0, dot);
      const fn = key.substring(dot + 1);
      functions.push({
        module: mod,
        function: fn,
        capabilities: Array.from(caps),
      });

      for (const c of caps) allCaps.add(c);
      totalFns++;
      const onlyPure = Array.from(caps).every((c) => c === 'pure');
      if (onlyPure) pureFns++;
      else effectfulFns++;
    }

    const capabilities: CapabilityEntry[] = [];
    for (const cap of ALL_CAPABILITIES) {
      if (!allCaps.has(cap) && cap !== 'pure') continue;
      const sites = this.capCallSites.get(cap) ?? [];
      if (cap === 'pure' && sites.length === 0 && allCaps.has(cap)) {
        capabilities.push({
          capability: cap,
          riskLevel: capabilityRiskLevel[cap],
          callSites: [],
        });
        continue;
      }
      if (sites.length > 0) {
        capabilities.push({
          capability: cap,
          riskLevel: capabilityRiskLevel[cap],
          callSites: sites.slice(),
        });
      }
    }

    const ioSites = this.capCallSites.get('io') ?? [];
    const summary: CapabilitySummary = {
      isPure: Array.from(allCaps).every((c) => c === 'pure'),
      readsFilesystem: allCaps.has('fs'),
      writesFilesystem: allCaps.has('fs'),
      readsStdin: ioSites.some((s) => s.calleeFunction === 'read_line'),
      writesStdout: ioSites.some(
        (s) => s.calleeFunction === 'print' || s.calleeFunction === 'print_error',
      ),
      writesStderr: ioSites.some((s) => s.calleeFunction === 'print_error'),
      readsEnvironment: ioSites.some(
        (s) => s.calleeFunction === 'env_get' || s.calleeFunction === 'args_get',
      ),
      controlsProcess: allCaps.has('process'),
      usesMemory: allCaps.has('memory'),
      usesTime: allCaps.has('time'),
      usesRandom: allCaps.has('random'),
      usesConcurrency: allCaps.has('concurrency'),
      usesNetwork: allCaps.has('network'),
      totalFunctions: totalFns,
      pureFunctions: pureFns,
      effectfulFunctions: effectfulFns,
    };

    return {
      programName: this.program.name ?? '',
      programVersion: this.program.version ?? '',
      capabilities,
      functions,
      summary,
    };
  }
}

// ── Formatting & policy helpers ─────────────────────────────────────────────

/** Format a capability report as human-readable text. */
export function formatCapabilityReport(report: BallCapabilityReport): string {
  const lines: string[] = [];
  const name = report.programName || '<unnamed>';
  const version = report.programVersion || '0.0.0';
  lines.push(`Ball Capability Audit: ${name} v${version}`);
  lines.push('='.repeat(60));
  lines.push('');

  lines.push('Capabilities:');
  for (const entry of report.capabilities) {
    const icon = entry.riskLevel === 'none' ? '\u2713' : '\u26A0';
    const siteCount = entry.callSites.length;
    if (siteCount === 0) {
      lines.push(`  ${icon} ${entry.capability} (pure computation)`);
    } else {
      const sites = entry.callSites
        .map(
          (s) =>
            `${s.module}.${s.function} \u2192 ${s.calleeModule}.${s.calleeFunction}`,
        )
        .join(', ');
      lines.push(`  ${icon} ${entry.capability} (${siteCount} call sites: ${sites})`);
    }
  }

  const absent: string[] = [];
  const s = report.summary;
  if (!s.readsFilesystem && !s.writesFilesystem) absent.push('filesystem');
  if (!s.usesNetwork) absent.push('network');
  if (!s.controlsProcess) absent.push('process');
  if (!s.usesMemory) absent.push('memory');
  if (!s.usesConcurrency) absent.push('concurrency');
  if (!s.usesRandom) absent.push('random');
  if (absent.length > 0) {
    lines.push(`  \u2717 NONE: ${absent.join(', ')}`);
  }

  lines.push('');
  const risk = s.isPure
    ? 'NO RISK \u2014 pure computation only'
    : s.controlsProcess || s.usesMemory || s.usesNetwork
    ? 'HIGH RISK'
    : s.readsFilesystem || s.writesFilesystem || s.usesConcurrency
    ? 'MEDIUM RISK'
    : 'LOW RISK';
  lines.push(`Summary: ${risk}`);
  lines.push(
    `  ${s.totalFunctions} functions: ${s.pureFunctions} pure, ${s.effectfulFunctions} effectful`,
  );

  lines.push('');
  lines.push('Per-function breakdown:');
  for (const fn of report.functions) {
    const caps = fn.capabilities.filter((c) => c !== 'pure');
    const label = caps.length === 0 ? 'pure' : caps.join(', ');
    lines.push(`  ${fn.module}.${fn.function} \u2192 ${label}`);
  }

  return lines.join('\n') + '\n';
}

/** Check a report against a deny list. Returns list of violations (empty = pass). */
export function checkPolicy(
  report: BallCapabilityReport,
  deny: ReadonlySet<string>,
): string[] {
  const violations: string[] = [];
  for (const entry of report.capabilities) {
    if (!deny.has(entry.capability)) continue;
    for (const site of entry.callSites) {
      violations.push(
        `${entry.capability}: ${site.module}.${site.function} calls ${site.calleeModule}.${site.calleeFunction}`,
      );
    }
  }
  return violations;
}
