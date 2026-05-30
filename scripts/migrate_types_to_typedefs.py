#!/usr/bin/env python3
"""One-shot migration: move every module's legacy `types[]` (bare
google.protobuf.DescriptorProto) into `typeDefs[]` (TypeDefinition) and retire
the legacy `_meta_<Name>` function hack.

Background: Ball historically declared a module's types two ways — bare
descriptors in `Module.types` (proto field 2) with cosmetic info smuggled into
companion `_meta_<Name>` functions — superseded by `Module.type_defs`
(TypeDefinition = name + descriptor + metadata). This script rewrites all
checked-in `.ball.json` programs to the `typeDefs`-only form so proto field 2
can be removed.

Transform, per module:
  * For each bare type T in `types`:
      - if a TypeDefinition with the same name already exists, drop T (the
        existing typeDef is strictly richer — same descriptor + metadata);
      - else append {name: T.name, descriptor: T} to `typeDefs`, folding in the
        metadata of a matching `_meta_<shortname>` function if present, and
        removing that `_meta_` function.
  * Delete `types`.

Idempotent: a module already in typeDefs-only form is left unchanged.

Usage:
  python scripts/migrate_types_to_typedefs.py [paths...]
  (defaults to tests/conformance/**/*.ball.json + examples/**/*.ball.json)
"""

import glob
import json
import os
import sys


def short(name: str) -> str:
    """Strip a `module:` prefix from a type name."""
    return name.split(":", 1)[1] if ":" in name else name


def migrate_module(m: dict) -> bool:
    types = m.get("types")
    if not types:
        return False  # nothing to do (idempotent)

    type_defs = m.get("typeDefs", [])
    existing = set()
    for td in type_defs:
        existing.add(td.get("name"))
        desc = td.get("descriptor")
        if isinstance(desc, dict) and "name" in desc:
            existing.add(desc["name"])

    # Index _meta_<Name> functions by the short type name they describe.
    meta_by_short = {}
    for f in m.get("functions", []):
        fn = f.get("name", "")
        if fn.startswith("_meta_"):
            meta_by_short[fn[len("_meta_"):]] = f

    consumed_meta = set()
    for t in types:
        tname = t.get("name")
        if tname in existing:
            continue  # richer typeDef already present
        td = {"name": tname, "descriptor": t}
        meta_fn = meta_by_short.get(short(tname))
        if meta_fn is not None and meta_fn.get("metadata"):
            td["metadata"] = meta_fn["metadata"]
            consumed_meta.add(meta_fn["name"])
        type_defs.append(td)
        existing.add(tname)

    if type_defs:
        m["typeDefs"] = type_defs
    del m["types"]

    # Drop the _meta_ functions whose metadata we folded into a typeDef.
    if consumed_meta:
        m["functions"] = [
            f for f in m.get("functions", []) if f.get("name") not in consumed_meta
        ]
    return True


def migrate_file(path: str) -> bool:
    with open(path, "r", encoding="utf-8") as fh:
        prog = json.load(fh)
    changed = False
    for m in prog.get("modules", []):
        if migrate_module(m):
            changed = True
    if changed:
        with open(path, "w", encoding="utf-8", newline="\n") as fh:
            json.dump(prog, fh, indent=2, ensure_ascii=False)
            fh.write("\n")
    return changed


def main(argv):
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    if argv:
        paths = argv
    else:
        paths = glob.glob(
            os.path.join(root, "tests", "conformance", "**", "*.ball.json"),
            recursive=True,
        ) + glob.glob(
            os.path.join(root, "examples", "**", "*.ball.json"), recursive=True
        )
    changed = 0
    for p in sorted(paths):
        if migrate_file(p):
            changed += 1
            print(f"  migrated {os.path.relpath(p, root)}")
    print(f"Done: {changed}/{len(paths)} files changed.")


if __name__ == "__main__":
    main(sys.argv[1:])
