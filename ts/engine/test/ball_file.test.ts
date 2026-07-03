/**
 * Tests for the engine-local ball-file envelope helper (src/ball_file.ts).
 * This is a trimmed duplicate of @ball-lang/shared's ball_file.ts that
 * operates on plain proto3-JSON (no protobuf-es dependency) — see its
 * module doc comment for why the duplication exists.
 */
import { test, describe } from "node:test";
import assert from "node:assert/strict";
import { unwrapBallFile } from "../src/ball_file.ts";

describe("unwrapBallFile", () => {
  test("passes through non-object input unchanged", () => {
    assert.equal(unwrapBallFile(null), null);
    assert.equal(unwrapBallFile(42), 42);
    assert.equal(unwrapBallFile("x"), "x");
    assert.deepEqual(unwrapBallFile([1, 2]), [1, 2]);
  });

  test("passes through an already-unwrapped object (no @type key)", () => {
    const bare = { name: "demo", entryModule: "main" };
    assert.equal(unwrapBallFile(bare), bare);
  });

  test("strips a recognized Program @type envelope", () => {
    const wrapped = { "@type": "type.googleapis.com/ball.v1.Program", name: "demo" };
    assert.deepEqual(unwrapBallFile(wrapped), { name: "demo" });
  });

  test("strips a recognized Module @type envelope", () => {
    const wrapped = { "@type": "type.googleapis.com/ball.v1.Module", name: "mymod" };
    assert.deepEqual(unwrapBallFile(wrapped), { name: "mymod" });
  });

  test("throws on an unrecognized @type", () => {
    assert.throws(
      () => unwrapBallFile({ "@type": "type.googleapis.com/ball.v1.Widget" }),
      /unknown ball file @type/,
    );
  });

  test("throws when @type is present but not a string", () => {
    assert.throws(
      () => unwrapBallFile({ "@type": 42 }),
      /unknown ball file @type/,
    );
  });
});
