/**
 * Tests for the static capability table (src/capability_table.ts).
 *
 * Dependency-free (no @ball-lang/engine import), so this suite runs standalone
 * even when the sibling workspace packages aren't linked.
 */
import { test, describe } from 'node:test';
import assert from 'node:assert/strict';
import {
  ALL_CAPABILITIES,
  CAPABILITY_TABLE,
  capabilityRiskLevel,
  lookupCapability,
} from '../src/capability_table.ts';
import type { Capability } from '../src/capability_table.ts';

describe('lookupCapability', () => {
  test('returns the mapped capability for a known base function', () => {
    assert.equal(lookupCapability('std', 'print'), 'io');
    assert.equal(lookupCapability('std_fs', 'file_read'), 'fs');
    assert.equal(lookupCapability('std_memory', 'memory_alloc'), 'memory');
    assert.equal(lookupCapability('std_concurrency', 'thread_spawn'), 'concurrency');
  });

  test('returns pure for pure base functions', () => {
    assert.equal(lookupCapability('std', 'add'), 'pure');
    assert.equal(lookupCapability('std_collections', 'list_map'), 'pure');
  });

  test('returns undefined for a user-defined (non-base) function', () => {
    assert.equal(lookupCapability('main', 'helper'), undefined);
  });

  test('returns undefined for a module.function pair not in the table', () => {
    assert.equal(lookupCapability('std', 'not_a_real_function'), undefined);
  });
});

describe('ALL_CAPABILITIES', () => {
  test('lists every Capability variant exactly once, pure first', () => {
    const expected: Capability[] = [
      'pure', 'io', 'fs', 'process', 'time', 'random', 'memory',
      'concurrency', 'network', 'async',
    ];
    assert.deepEqual(ALL_CAPABILITIES, expected);
    assert.equal(new Set(ALL_CAPABILITIES).size, ALL_CAPABILITIES.length);
  });
});

describe('capabilityRiskLevel', () => {
  test('assigns a risk level to every capability', () => {
    for (const cap of ALL_CAPABILITIES) {
      assert.ok(
        typeof capabilityRiskLevel[cap] === 'string' && capabilityRiskLevel[cap].length > 0,
        `missing risk level for ${cap}`,
      );
    }
  });

  test('pure is none risk; process/memory/network are high risk', () => {
    assert.equal(capabilityRiskLevel.pure, 'none');
    assert.equal(capabilityRiskLevel.process, 'high');
    assert.equal(capabilityRiskLevel.memory, 'high');
    assert.equal(capabilityRiskLevel.network, 'high');
  });
});

describe('CAPABILITY_TABLE', () => {
  test('every entry key is a "module.function" pair with a valid Capability value', () => {
    const validCaps = new Set<string>(ALL_CAPABILITIES);
    for (const [key, cap] of Object.entries(CAPABILITY_TABLE)) {
      assert.ok(key.includes('.'), `key ${key} should be module.function`);
      assert.ok(validCaps.has(cap), `${key} has invalid capability ${cap}`);
    }
  });

  test('every std_memory entry is capability "memory"', () => {
    for (const [key, cap] of Object.entries(CAPABILITY_TABLE)) {
      if (key.startsWith('std_memory.')) assert.equal(cap, 'memory', key);
    }
  });

  test('every std_collections entry is pure', () => {
    for (const [key, cap] of Object.entries(CAPABILITY_TABLE)) {
      if (key.startsWith('std_collections.')) assert.equal(cap, 'pure', key);
    }
  });
});
