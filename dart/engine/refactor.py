"""
Refactor engine.dart: systematically fix BallValue type errors by adding
wrap() calls at return points and unwrap() where raw types are needed.
"""
import re
import sys

def process(content: str) -> str:
    lines = content.split('\n')
    out = []

    for i, line in enumerate(lines):
        s = line.lstrip()

        # Skip comments
        if s.startswith('//') or s.startswith('///') or s.startswith('*'):
            out.append(line)
            continue

        # === Pattern: Map<String, Object?> type references ===
        # 'is Map<String, Object?>' -> 'is BallMap'
        line = line.replace('is Map<String, Object?>', 'is BallMap')
        line = line.replace('is! Map<String, Object?>', 'is! BallMap')

        # 'as Map<String, Object?>' -> cast via _asMap or keep with wrapping
        # Be careful: '(i as Map<String, Object?>)' in closures
        line = line.replace('as Map<String, Object?>', 'as BallMap')

        # Map<String, Object?> in local variable type annotations used for creating maps
        # 'final instance = <String, Object?>{};' -> 'final instance = BallMap();'
        # 'final fields = <String, Object?>{};' -> 'final fields = BallMap();'
        # '<String, Object?>{}' map literal -> 'BallMap()'
        line = re.sub(r'<String,\s*Object\?>\s*\{\}', 'BallMap()', line)

        # '<String, Object?>{...}' with contents - trickier
        # 'Map<String, Object?>.from(input)' -> BallMap(Map.from(input.entries))
        # Skip these for now - too complex

        # Map.from patterns
        line = line.replace('Map<String, Object?>.from(input)', 'BallMap(Map<String, BallValue>.from((input as BallMap).entries))')

        # '<Object?>' list types
        line = line.replace('<Object?>[]', '<BallValue>[]')
        line = line.replace('List<Object?>', 'List<BallValue>')

        out.append(line)

    return '\n'.join(out)

if __name__ == '__main__':
    path = sys.argv[1]
    with open(path, 'r', encoding='utf-8') as f:
        content = f.read()

    before = content.count('\n')
    result = process(content)
    after = result.count('\n')

    with open(path, 'w', encoding='utf-8') as f:
        f.write(result)

    print(f"Lines: {before} -> {after}")
