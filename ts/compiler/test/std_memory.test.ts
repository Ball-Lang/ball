/**
 * std_memory native lowering for the TS compiler.
 *
 * Prior to this test, `std_memory` calls fell into `compileStdCall`'s
 * generic default case and were emitted as bare/undefined identifiers
 * (`/* std.memory_realloc *\/ memory_realloc(...)`) — a compile-time
 * silent-failure (#157). The TS compiler now natively lowers every
 * std_memory base function (dart/shared/lib/std_memory.dart) to a
 * `ByteData`-backed linear memory simulation mirroring the Dart compiler's
 * `_compileMemoryCall` (dart/compiler/lib/compiler.dart), and throws a
 * compile-time Error for any std_memory function it does not implement.
 *
 * Run: node --experimental-strip-types --test test/*.test.ts
 */
import { test, describe } from "node:test";
import assert from "node:assert/strict";
import { readFileSync, writeFileSync, unlinkSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { execSync } from "node:child_process";
import { compile } from "../src/index.ts";
import type { Expression, FunctionDef, Program } from "../src/index.ts";

// ── Test-program builders ──────────────────────────────────────────

/** A `std_memory` module import — only its presence/emptiness matters to
 *  the compiler's `usesStdMemory` detection (mirrors the Dart compiler's
 *  `_baseModules.contains('std_memory')`). */
const STD_MEMORY_MODULE = {
  name: "std_memory",
  functions: [{ name: "memory_alloc", isBase: true }] as FunctionDef[],
};

function call(fn: string, fields: Record<string, Expression> = {}): Expression {
  return {
    call: {
      module: "std_memory",
      function: fn,
      input: fields && Object.keys(fields).length > 0
        ? { messageCreation: { fields: Object.entries(fields).map(([name, value]) => ({ name, value })) } }
        : undefined,
    },
  };
}

const intLit = (n: number): Expression => ({ literal: { intValue: n } });
const ref = (name: string): Expression => ({ reference: { name } });

/** Builds a minimal program whose `main` body is the given block statements
 *  plus a trailing `result`, with `std_memory` imported. */
function programWithMemory(statements: { let?: { name: string; value?: Expression }; expression?: Expression }[]): Program {
  return {
    name: "std_memory_test",
    entryModule: "main",
    entryFunction: "main",
    modules: [
      STD_MEMORY_MODULE,
      {
        name: "main",
        functions: [
          {
            name: "main",
            body: { block: { statements, result: { literal: { intValue: 0 } } } },
          },
        ],
      },
    ],
  };
}

function printCall(value: Expression): Expression {
  return {
    call: {
      module: "std",
      function: "print",
      input: { messageCreation: { fields: [{ name: "message", value }] } },
    },
  };
}

// ── Emitted-code-shape unit tests ────────────────────────────────────

describe("TS compiler — std_memory lowering (shapes)", () => {
  test("preamble: _ballMemory/_ballHeapPtr/_ballStackFrames/_ballStackPtr are emitted only when std_memory is imported", () => {
    const withMem = compile(programWithMemory([]));
    assert.match(withMem, /const _ballMemory = new ByteData\(65536\);/);
    assert.match(withMem, /let _ballHeapPtr = 0;/);
    assert.match(withMem, /const _ballStackFrames: number\[\] = \[\];/);
    assert.match(withMem, /let _ballStackPtr = 65536;/);

    const withoutMem: Program = {
      name: "no_memory",
      entryModule: "main",
      entryFunction: "main",
      modules: [
        { name: "main", functions: [{ name: "main", body: intLit(0) }] },
      ],
    };
    const bare = compile(withoutMem);
    assert.doesNotMatch(bare, /_ballMemory/);
    assert.doesNotMatch(bare, /_ballHeapPtr/);
  });

  test("memory_alloc bump-allocates from _ballHeapPtr", () => {
    const ts = compile(
      programWithMemory([{ expression: call("memory_alloc", { size: intLit(8) }) }]),
      { includePreamble: false },
    );
    assert.match(ts, /const __addr = _ballHeapPtr; _ballHeapPtr \+= 8; return __addr;/);
  });

  test("memory_free is a noop (never a bare/undefined identifier)", () => {
    const ts = compile(
      programWithMemory([{ expression: call("memory_free", { address: intLit(4) }) }]),
      { includePreamble: false },
    );
    assert.doesNotMatch(ts, /\bmemory_free\(/);
    assert.match(ts, /noop in TS/);
  });

  test("memory_realloc bump-allocates and copies clamped bytes from the old block", () => {
    const ts = compile(
      programWithMemory([
        { expression: call("memory_realloc", { address: intLit(0), new_size: intLit(16) }) },
      ]),
      { includePreamble: false },
    );
    assert.match(ts, /_ballHeapPtr \+= __size/);
    assert.match(ts, /_ballMemory\.setUint8\(__addr \+ __i, _ballMemory\.getUint8\(__old \+ __i\)\)/);
  });

  test("typed reads/writes address the ByteData with Endian.little (except 8-bit)", () => {
    const ts = compile(
      programWithMemory([
        { expression: call("memory_write_i32", { address: intLit(0), value: intLit(42) }) },
        { expression: call("memory_read_i32", { address: intLit(0) }) },
        { expression: call("memory_write_u8", { address: intLit(4), value: intLit(9) }) },
      ]),
      { includePreamble: false },
    );
    assert.match(ts, /_ballMemory\.setInt32\(0, 42, Endian\.little\)/);
    assert.match(ts, /_ballMemory\.getInt32\(0, Endian\.little\)/);
    assert.match(ts, /_ballMemory\.setUint8\(4, 9\)/);
  });

  test("i64/u64 read/write use ByteData's bigint-typed accessors, writes coerce via BigInt(...)", () => {
    const ts = compile(
      programWithMemory([
        { expression: call("memory_write_i64", { address: intLit(0), value: intLit(123) }) },
        { expression: call("memory_write_u64", { address: intLit(8), value: intLit(456) }) },
        { expression: call("memory_read_i64", { address: intLit(0) }) },
        { expression: call("memory_read_u64", { address: intLit(8) }) },
      ]),
      { includePreamble: false },
    );
    assert.match(ts, /_ballMemory\.setInt64\(0, BigInt\(123\), Endian\.little\)/);
    assert.match(ts, /_ballMemory\.setUint64\(8, BigInt\(456\), Endian\.little\)/);
    assert.match(ts, /_ballMemory\.getInt64\(0, Endian\.little\)/);
    assert.match(ts, /_ballMemory\.getUint64\(8, Endian\.little\)/);
  });

  test("ptr_add/ptr_sub/ptr_diff compile to pointer arithmetic", () => {
    const ts = compile(
      programWithMemory([
        { expression: call("ptr_add", { address: intLit(0), offset: intLit(2), element_size: intLit(4) }) },
        { expression: call("ptr_sub", { address: intLit(16), offset: intLit(1), element_size: intLit(4) }) },
        { expression: call("ptr_diff", { address: intLit(16), offset: intLit(0), element_size: intLit(4) }) },
      ]),
      { includePreamble: false },
    );
    assert.match(ts, /\(0 \+ \(2 \* 4\)\)/);
    assert.match(ts, /\(16 - \(1 \* 4\)\)/);
    assert.match(ts, /Math\.trunc\(\(16 - 0\) \/ 4\)/);
  });

  test("stack_alloc/stack_push_frame/stack_pop_frame manage the stack pointer", () => {
    const ts = compile(
      programWithMemory([
        { expression: call("stack_push_frame") },
        { expression: call("stack_alloc", { size: intLit(4) }) },
        { expression: call("stack_pop_frame") },
      ]),
      { includePreamble: false },
    );
    assert.match(ts, /_ballStackPtr -= 4; return _ballStackPtr;/);
    assert.match(ts, /_ballStackFrames\.push\(_ballStackPtr\)/);
    assert.match(ts, /_ballStackPtr = _ballStackFrames\.pop\(\)!/);
  });

  test("memory_sizeof folds known type names to byte sizes at compile time", () => {
    const sizeofCall = (t: string) => call("memory_sizeof", { type_name: { literal: { stringValue: t } } });
    const ts = compile(
      programWithMemory([
        { expression: sizeofCall("int8") },
        { expression: sizeofCall("int32") },
        { expression: sizeofCall("double") },
        { expression: sizeofCall("some_unknown_type") },
      ]),
      { includePreamble: false },
    );
    const returns = [...ts.matchAll(/^\s*(\d+);\s*$/gm)].map((m) => m[1]);
    assert.deepEqual(returns, ["1", "4", "8", "8"]);
  });

  test("nullptr/memory_heap_size/memory_stack_size", () => {
    const ts = compile(
      programWithMemory([
        { expression: call("nullptr") },
        { expression: call("memory_heap_size") },
        { expression: call("memory_stack_size") },
      ]),
      { includePreamble: false },
    );
    assert.match(ts, /_ballMemory\.lengthInBytes/);
    assert.match(ts, /\(_ballMemory\.lengthInBytes - _ballStackPtr\)/);
  });

  test("deref reads a pointer-sized (64-bit) int", () => {
    const ts = compile(
      programWithMemory([{ expression: call("deref", { pointer: intLit(0) }) }]),
      { includePreamble: false },
    );
    assert.match(ts, /_ballMemory\.getInt64\(0, Endian\.little\)/);
  });

  test("an unimplemented std_memory function throws a compile-time Error naming it (fail loud, #157)", () => {
    const program = programWithMemory([{ expression: call("memory_frobnicate", { address: intLit(0) }) }]);
    assert.throws(
      () => compile(program),
      /std_memory\.memory_frobnicate is not implemented/,
    );
  });
});

// ── Executed end-to-end test ─────────────────────────────────────────

describe("TS compiler — std_memory executed end-to-end", () => {
  test("alloc/write/realloc/read round-trips real bytes through node", () => {
    // let a = memory_alloc(size: 8);
    // memory_write_u32(address: a, value: 0x11223344);
    // memory_write_u8(address: ptr_add(a, 4, 1), value: 99);
    // print(memory_read_u32(address: a));       -> 287454020
    // print(memory_read_u8(address: ptr_add(a, 4, 1))); -> 99
    // let b = memory_realloc(address: a, new_size: 16);
    // print(memory_read_u32(address: b));       -> 287454020 (copied)
    // print(memory_read_u8(address: ptr_add(b, 4, 1))); -> 99 (copied)
    // memory_write_i64(address: b + 8-ish offset via a second alloc, value: -5)
    const off4 = (base: string) => call("ptr_add", { address: ref(base), offset: intLit(4), element_size: intLit(1) });

    const program = programWithMemory([
      { let: { name: "a", value: call("memory_alloc", { size: intLit(8) }) } },
      { expression: call("memory_write_u32", { address: ref("a"), value: intLit(0x11223344) }) },
      { expression: call("memory_write_u8", { address: off4("a"), value: intLit(99) }) },
      { expression: printCall(call("memory_read_u32", { address: ref("a") })) },
      { expression: printCall(call("memory_read_u8", { address: off4("a") })) },
      { let: { name: "b", value: call("memory_realloc", { address: ref("a"), new_size: intLit(16) }) } },
      { expression: printCall(call("memory_read_u32", { address: ref("b") })) },
      { expression: printCall(call("memory_read_u8", { address: off4("b") })) },
      {
        let: {
          name: "c",
          value: call("memory_alloc", { size: intLit(8) }),
        },
      },
      { expression: call("memory_write_i64", { address: ref("c"), value: intLit(-5) }) },
      { expression: printCall(call("memory_read_i64", { address: ref("c") })) },
    ]);

    const ts = compile(program);
    const tmpPath = join(tmpdir(), `ball_std_memory_${process.pid}.ts`);
    writeFileSync(tmpPath, ts);
    try {
      let stdout: string;
      try {
        stdout = execSync(`node --experimental-strip-types "${tmpPath}"`, {
          encoding: "utf8",
          stdio: ["ignore", "pipe", "pipe"],
        });
      } catch (e: any) {
        throw new Error(`Node failed:\nstderr:\n${e.stderr}\n\n---compiled---\n${ts}`);
      }
      const lines = stdout.replace(/\r\n/g, "\n").trimEnd().split("\n");
      assert.deepEqual(lines, ["287454020", "99", "287454020", "99", "-5"]);
    } finally {
      try { unlinkSync(tmpPath); } catch { /* ignore */ }
    }
  });

  test("memory_copy/memory_set/memory_compare round-trip real bytes through node", () => {
    // let a = memory_alloc(size: 8); memory_write_u32(a, 0x11223344);
    // let b = memory_alloc(size: 8); memory_write_u32(b, 0x11223344);
    // print(memory_compare(a, b, size: 4));      -> 0 (equal)
    // memory_set(address: b, value: 0, size: 4); print(memory_read_u32(b)); -> 0
    // print(memory_compare(a, b, size: 4));      -> 68 (0x44 - 0, first differing byte)
    // memory_copy(dest: b, src: a, size: 4); print(memory_read_u32(b)); -> 287454020 (copied)
    // print(memory_compare(a, b, size: 4));      -> 0 (equal again)
    const program = programWithMemory([
      { let: { name: "a", value: call("memory_alloc", { size: intLit(8) }) } },
      { expression: call("memory_write_u32", { address: ref("a"), value: intLit(0x11223344) }) },
      { let: { name: "b", value: call("memory_alloc", { size: intLit(8) }) } },
      { expression: call("memory_write_u32", { address: ref("b"), value: intLit(0x11223344) }) },
      { expression: printCall(call("memory_compare", { a: ref("a"), b: ref("b"), size: intLit(4) })) },
      { expression: call("memory_set", { address: ref("b"), value: intLit(0), size: intLit(4) }) },
      { expression: printCall(call("memory_read_u32", { address: ref("b") })) },
      { expression: printCall(call("memory_compare", { a: ref("a"), b: ref("b"), size: intLit(4) })) },
      { expression: call("memory_copy", { dest: ref("b"), src: ref("a"), size: intLit(4) }) },
      { expression: printCall(call("memory_read_u32", { address: ref("b") })) },
      { expression: printCall(call("memory_compare", { a: ref("a"), b: ref("b"), size: intLit(4) })) },
    ]);

    const ts = compile(program);
    const tmpPath = join(tmpdir(), `ball_std_memory_bulk_${process.pid}.ts`);
    writeFileSync(tmpPath, ts);
    try {
      let stdout: string;
      try {
        stdout = execSync(`node --experimental-strip-types "${tmpPath}"`, {
          encoding: "utf8",
          stdio: ["ignore", "pipe", "pipe"],
        });
      } catch (e: any) {
        throw new Error(`Node failed:\nstderr:\n${e.stderr}\n\n---compiled---\n${ts}`);
      }
      const lines = stdout.replace(/\r\n/g, "\n").trimEnd().split("\n");
      assert.deepEqual(lines, ["0", "0", "68", "287454020", "0"]);
    } finally {
      try { unlinkSync(tmpPath); } catch { /* ignore */ }
    }
  });
});
