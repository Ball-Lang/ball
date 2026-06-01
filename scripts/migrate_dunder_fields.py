#!/usr/bin/env python3
"""Migrate remaining __dunder__ field hacks to structured proto fields.

Handles:
1. __const__ in MessageCreation.fields → MessageCreation.metadata.is_const
2. __cascade_self__ Reference name → Reference.isCascadeTarget
3. __no_init__ Reference name → LetBinding.metadata.is_late
"""

import json
import os
import sys
from pathlib import Path


def migrate_file(path: str) -> tuple[int, int, int]:
    """Migrate a single Ball JSON file. Returns (const_count, cascade_count, noinit_count)."""
    with open(path, 'r', encoding='utf-8') as f:
        data = json.load(f)

    const_count = 0
    cascade_count = 0
    noinit_count = 0

    def walk(obj):
        nonlocal const_count, cascade_count, noinit_count

        if isinstance(obj, dict):
            # 1. __const__ in MessageCreation.fields → metadata.is_const
            if 'messageCreation' in obj:
                mc = obj['messageCreation']
                fields = mc.get('fields', [])
                new_fields = []
                found_const = False
                for f in fields:
                    if f.get('name') == '__const__':
                        val = f.get('value', {})
                        lit = val.get('literal', {})
                        if lit.get('boolValue', False):
                            found_const = True
                    else:
                        new_fields.append(f)
                if found_const:
                    mc['fields'] = new_fields
                    meta = mc.get('metadata', {})
                    meta['is_const'] = True
                    mc['metadata'] = meta
                    const_count += 1

            # 2. __cascade_self__ Reference → isCascadeTarget
            if 'reference' in obj:
                ref = obj['reference']
                if ref.get('name') == '__cascade_self__':
                    ref['name'] = 'self'
                    ref['isCascadeTarget'] = True
                    cascade_count += 1

            # 3. __no_init__ in LetBinding value → metadata.is_late
            if 'let' in obj:
                let_bind = obj['let']
                val = let_bind.get('value', {})
                ref = val.get('reference', {})
                if ref.get('name') == '__no_init__':
                    meta = let_bind.get('metadata', {})
                    meta['is_late'] = True
                    let_bind['metadata'] = meta
                    let_bind.pop('value', None)
                    noinit_count += 1

            for v in obj.values():
                walk(v)
        elif isinstance(obj, list):
            for v in obj:
                walk(v)

    walk(data)

    total = const_count + cascade_count + noinit_count
    if total > 0:
        with open(path, 'w', encoding='utf-8') as f:
            json.dump(data, f, indent=2)
            f.write('\n')

    return const_count, cascade_count, noinit_count


def main():
    root = Path(__file__).parent.parent
    patterns = [
        root / 'tests' / 'conformance',
        root / 'tests' / 'fixtures',
        root / 'examples',
        root / 'dart' / 'self_host',
    ]

    total_const = 0
    total_cascade = 0
    total_noinit = 0
    modified_files = []

    for pattern_dir in patterns:
        if not pattern_dir.exists():
            continue
        for ball_file in sorted(pattern_dir.rglob('*.ball.json')):
            c, cas, n = migrate_file(str(ball_file))
            if c + cas + n > 0:
                modified_files.append(str(ball_file.relative_to(root)))
                total_const += c
                total_cascade += cas
                total_noinit += n

    print(f'Migration complete:')
    print(f'  __const__ -> metadata.is_const: {total_const}')
    print(f'  __cascade_self__ -> isCascadeTarget: {total_cascade}')
    print(f'  __no_init__ -> metadata.is_late: {total_noinit}')
    print(f'  Files modified: {len(modified_files)}')
    for f in modified_files:
        print(f'    {f}')


if __name__ == '__main__':
    main()
