# Deterministic Ball-IR transforms — bulk edits without token spend

The Ball IR is **proto3 JSON** (`.ball.json`) or binary protobuf (`.ball.bin`/`.ball.pb`). Bulk structural edits — renames, module regrouping, file-name mapping, call-target rewrites — are small scripts over that JSON. Token cost is O(script), not O(codebase); a 40-file rename is the same 20-line script as a 4,000-file rename.

## File shape

A `.ball.json` file may be a self-describing `google.protobuf.Any` envelope:

```json
{ "@type": "type.googleapis.com/ball.v1.Program", "modules": [ ... ], ... }
```

Strip the `"@type"` key before handing the object to a compiler API; CLI tools accept the envelope as-is.

## The semantic/cosmetic boundary (the safety invariant)

- **Semantic** (changes program behavior): expression trees (`call`, `literal`, `reference`, `fieldAccess`, `messageCreation`, `block`, `lambda`), function signatures, `typeDefs[]` descriptors, module structure.
- **Cosmetic** (never changes behavior): every `google.protobuf.Struct metadata` field — names for humans, formatting hints, file mapping. **Stripping all metadata must never change what a program computes.** Ball's compilers and engines are built to this invariant.

Consequence: any transform that touches only `metadata` is provably semantics-preserving. Style and naming transforms therefore belong in metadata, and can be applied fearlessly at scale.

## Transform workflow

1. Write the transform as a script (node/jq/dart — anything that round-trips JSON faithfully; beware integer precision above 2^53, prefer a proto-aware runtime for semantic edits).
2. Apply it to every `.ball.json`.
3. **Validate**: `ball validate <file>` on each output.
4. **Verify semantics held**: run the transformed IR on the engine (`ball run` / `@ball-lang/cli run`) against the golden outputs captured before the transform. Metadata-only transforms must produce byte-identical outputs.
5. Re-emit target source from the transformed IR. Never patch emitted files directly.

## Example — bulk symbol rename via metadata (node)

```js
// rename_symbols.mjs — applies a name map to cosmetic metadata across programs
import { readFileSync, writeFileSync } from 'fs';
const nameMap = JSON.parse(readFileSync('name_map.json', 'utf8')); // {"old_name": "NewName", ...}
for (const path of process.argv.slice(2)) {
  const prog = JSON.parse(readFileSync(path, 'utf8'));
  const walk = (node) => {
    if (node === null || typeof node !== 'object') return;
    if (Array.isArray(node)) return node.forEach(walk);
    // cosmetic display names live in metadata Structs
    if (typeof node.metadata === 'object' && node.metadata !== null) {
      for (const key of ['name', 'display_name', 'file_name']) {
        const v = node.metadata[key];
        if (typeof v === 'string' && nameMap[v]) node.metadata[key] = nameMap[v];
      }
    }
    Object.values(node).forEach(walk);
  };
  walk(prog);
  writeFileSync(path, JSON.stringify(prog, null, 2));
}
```

Semantic renames (function names referenced by `call` expressions) additionally rewrite the `call` target strings and the function declarations together — do both in one script pass so no intermediate state exists, then run step 4's engine check.

## Anti-patterns

- Editing emitted target files by hand or with an LLM (they are generated artifacts; the edit dies on the next emission).
- LLM-rewriting IR JSON inline in the conversation (burning tokens on mechanical work a script does deterministically).
- Skipping the engine re-run after a "cosmetic" transform (typos in scripts make cosmetic edits semantic; the engine check catches this in seconds).
