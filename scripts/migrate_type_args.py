#!/usr/bin/env python3
"""
Migrate Ball conformance programs from old __type_args__ string convention
and std.is/std.as "type" field convention to the new FunctionCall.type_args
TypeRef format.

Two migrations:
1. __type_args__ in call.input.messageCreation.fields -> call.typeArgs
2. std.is/std.as "type" field in call.input.messageCreation.fields -> call.typeArgs[0]

Also handles __type_args__ in standalone messageCreation (not inside a call.input)
by removing the field (the type info is cosmetic in that context).
"""

import json
import os
import re
import sys
from pathlib import Path
from typing import Any


# ---------------------------------------------------------------------------
# Type-string parser
# ---------------------------------------------------------------------------

def parse_type_string(s: str) -> dict:
    """Parse a Dart-flavored type string into a TypeRef dict.

    Examples:
        "int"                       -> {"name": "int"}
        "int?"                      -> {"name": "int", "nullable": true}
        "Box<int>"                  -> {"name": "Box", "typeArgs": [{"name": "int"}]}
        "Map<String, List<int>>"    -> {"name": "Map", "typeArgs": [...]}
    """
    s = s.strip()
    result, pos = _parse_type_at(s, 0)
    if pos != len(s):
        raise ValueError(f"Unexpected trailing characters at position {pos} in {s!r}: {s[pos:]!r}")
    return result


def _parse_type_at(s: str, pos: int) -> tuple[dict, int]:
    """Parse a single type starting at `pos`, return (TypeRef dict, next pos)."""
    # Read the base name (letters, digits, underscores, colons for module-qualified)
    start = pos
    while pos < len(s) and (s[pos].isalnum() or s[pos] in ('_', ':', '.')):
        pos += 1
    if pos == start:
        raise ValueError(f"Expected type name at position {pos} in {s!r}")
    name = s[start:pos]

    result: dict[str, Any] = {"name": name}

    # Check for generic type arguments <...>
    if pos < len(s) and s[pos] == '<':
        type_args, pos = _parse_type_args_list(s, pos)
        if type_args:
            result["typeArgs"] = type_args

    # Check for nullable suffix ?
    if pos < len(s) and s[pos] == '?':
        result["nullable"] = True
        pos += 1

    return result, pos


def _parse_type_args_list(s: str, pos: int) -> tuple[list[dict], int]:
    """Parse <T1, T2, ...> starting at the '<' at `pos`."""
    assert s[pos] == '<'
    pos += 1  # skip '<'
    args = []

    # Skip whitespace
    while pos < len(s) and s[pos] == ' ':
        pos += 1

    if pos < len(s) and s[pos] == '>':
        return args, pos + 1

    while True:
        # Skip whitespace
        while pos < len(s) and s[pos] == ' ':
            pos += 1

        arg, pos = _parse_type_at(s, pos)
        args.append(arg)

        # Skip whitespace
        while pos < len(s) and s[pos] == ' ':
            pos += 1

        if pos < len(s) and s[pos] == ',':
            pos += 1  # skip ','
            continue
        elif pos < len(s) and s[pos] == '>':
            pos += 1  # skip '>'
            break
        else:
            raise ValueError(f"Expected ',' or '>' at position {pos} in {s!r}")

    return args, pos


def parse_type_args_string(s: str) -> list[dict]:
    """Parse a __type_args__ string like "<int>" or "<int, String>".

    Strips outer angle brackets and parses inner comma-separated type list.
    """
    s = s.strip()
    if s.startswith('<') and s.endswith('>'):
        inner = s[1:-1].strip()
        if not inner:
            return []
        # Parse as comma-separated types
        args = []
        pos = 0
        while pos < len(inner):
            while pos < len(inner) and inner[pos] == ' ':
                pos += 1
            if pos >= len(inner):
                break
            arg, pos = _parse_type_at(inner, pos)
            args.append(arg)
            while pos < len(inner) and inner[pos] == ' ':
                pos += 1
            if pos < len(inner) and inner[pos] == ',':
                pos += 1
        return args
    else:
        raise ValueError(f"Expected __type_args__ string to be wrapped in <>, got: {s!r}")


def clean_type_ref(tr: dict) -> dict:
    """Remove default values from TypeRef for proto3 JSON compliance.

    - Remove 'nullable' if False (proto3 JSON omits default values)
    - Remove 'typeArgs' if empty list
    """
    result: dict[str, Any] = {"name": tr["name"]}
    if tr.get("typeArgs"):
        result["typeArgs"] = [clean_type_ref(a) for a in tr["typeArgs"]]
    if tr.get("nullable"):
        result["nullable"] = True
    return result


# ---------------------------------------------------------------------------
# JSON tree walker
# ---------------------------------------------------------------------------

class MigrationStats:
    def __init__(self):
        self.type_args_in_call = 0
        self.type_args_standalone = 0
        self.is_as_migrated = 0
        self.files_modified = 0


def migrate_node(node: Any, parent: Any = None, parent_key: str | None = None,
                 stats: MigrationStats = None) -> Any:
    """Recursively walk the JSON tree and perform migrations.

    We look for two patterns:
    1. A "call" object whose "input" has "messageCreation" with a "__type_args__" field
    2. A "call" object with module="std", function="is"|"as" whose input messageCreation
       has a "type" field with a string literal
    """
    if isinstance(node, dict):
        # Check if this is a "call" node (i.e., a dict that has a "call" key
        # whose value is the FunctionCall object)
        if "call" in node and isinstance(node["call"], dict):
            call_obj = node["call"]
            _migrate_call(call_obj, stats)
            # Continue recursing into the call object
            for key, value in list(call_obj.items()):
                call_obj[key] = migrate_node(value, call_obj, key, stats)
            # Also recurse into other keys of the parent dict (besides "call")
            for key, value in list(node.items()):
                if key != "call":
                    node[key] = migrate_node(value, node, key, stats)
            return node

        # Check for standalone messageCreation with __type_args__
        if "messageCreation" in node and isinstance(node["messageCreation"], dict):
            mc = node["messageCreation"]
            fields = mc.get("fields", [])
            ta_field = None
            for f in fields:
                if f.get("name") == "__type_args__":
                    ta_field = f
                    break
            if ta_field is not None:
                # Standalone messageCreation (not inside a call.input) — just remove __type_args__
                fields.remove(ta_field)
                if not fields:
                    del mc["fields"]
                if stats:
                    stats.type_args_standalone += 1

        # General recursion
        for key, value in list(node.items()):
            node[key] = migrate_node(value, node, key, stats)
        return node

    elif isinstance(node, list):
        for i, item in enumerate(node):
            node[i] = migrate_node(item, node, str(i), stats)
        return node

    return node


def _migrate_call(call_obj: dict, stats: MigrationStats | None):
    """Migrate a FunctionCall object in-place."""
    input_expr = call_obj.get("input")
    if not isinstance(input_expr, dict):
        return

    mc = input_expr.get("messageCreation")
    if not isinstance(mc, dict):
        return

    fields = mc.get("fields", [])

    # Migration 1: __type_args__ field
    ta_field = None
    for f in fields:
        if f.get("name") == "__type_args__":
            ta_field = f
            break

    if ta_field is not None:
        # Extract the string value
        literal = ta_field.get("value", {}).get("literal", {})
        ta_string = literal.get("stringValue", "")
        if ta_string:
            type_args = parse_type_args_string(ta_string)
            type_args = [clean_type_ref(tr) for tr in type_args]
            if type_args:
                existing = call_obj.get("typeArgs", [])
                call_obj["typeArgs"] = existing + type_args
        # Remove __type_args__ field from messageCreation
        fields.remove(ta_field)
        if not fields:
            if "fields" in mc:
                del mc["fields"]
        if stats:
            stats.type_args_in_call += 1

    # Migration 2: std.is / std.as "type" field
    module = call_obj.get("module", "")
    function = call_obj.get("function", "")
    if module == "std" and function in ("is", "as"):
        type_field = None
        for f in fields:
            if f.get("name") == "type":
                type_field = f
                break
        if type_field is not None:
            literal = type_field.get("value", {}).get("literal", {})
            type_string = literal.get("stringValue", "")
            if type_string:
                type_ref = parse_type_string(type_string)
                type_ref = clean_type_ref(type_ref)
                existing = call_obj.get("typeArgs", [])
                # Insert at position 0
                call_obj["typeArgs"] = [type_ref] + existing
                # Remove "type" field from messageCreation
                fields.remove(type_field)
                if not fields:
                    if "fields" in mc:
                        del mc["fields"]
                if stats:
                    stats.is_as_migrated += 1


# ---------------------------------------------------------------------------
# File processing
# ---------------------------------------------------------------------------

def process_file(filepath: str, stats: MigrationStats) -> bool:
    """Process a single .ball.json file. Returns True if modified."""
    with open(filepath, 'r', encoding='utf-8') as f:
        original = f.read()

    try:
        data = json.loads(original)
    except json.JSONDecodeError as e:
        print(f"  WARNING: Could not parse {filepath}: {e}")
        return False

    # Handle @type wrapper — migrate the inner content
    migrate_node(data, stats=stats)

    # Serialize back with indent=2 and trailing newline
    new_content = json.dumps(data, indent=2, ensure_ascii=False) + '\n'

    if new_content != original:
        with open(filepath, 'w', encoding='utf-8', newline='\n') as f:
            f.write(new_content)
        return True
    return False


def find_ball_json_files(root: str) -> list[str]:
    """Find all .ball.json files in the repository."""
    files = []
    for dirpath, dirnames, filenames in os.walk(root):
        # Skip node_modules, .git, build directories, worktrees, etc.
        dirnames[:] = [d for d in dirnames if d not in
                       ('.git', 'node_modules', 'build', 'gen', '.dart_tool',
                        '.claude', '.omc')]
        for fn in filenames:
            if fn.endswith('.ball.json'):
                files.append(os.path.join(dirpath, fn))
    return sorted(files)


def main():
    repo_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    print(f"Repository root: {repo_root}")

    # Find all .ball.json files
    all_files = find_ball_json_files(repo_root)
    print(f"Found {len(all_files)} .ball.json files")

    stats = MigrationStats()
    modified_files = []

    for filepath in all_files:
        rel = os.path.relpath(filepath, repo_root)
        old_stats = (stats.type_args_in_call, stats.type_args_standalone, stats.is_as_migrated)

        modified = process_file(filepath, stats)
        if modified:
            new_stats = (stats.type_args_in_call, stats.type_args_standalone, stats.is_as_migrated)
            delta_call = new_stats[0] - old_stats[0]
            delta_standalone = new_stats[1] - old_stats[1]
            delta_is_as = new_stats[2] - old_stats[2]
            details = []
            if delta_call:
                details.append(f"{delta_call} call __type_args__")
            if delta_standalone:
                details.append(f"{delta_standalone} standalone __type_args__")
            if delta_is_as:
                details.append(f"{delta_is_as} is/as type")
            print(f"  MODIFIED: {rel} ({', '.join(details)})")
            modified_files.append(rel)
            stats.files_modified += 1

    print(f"\n=== Migration Summary ===")
    print(f"Files scanned: {len(all_files)}")
    print(f"Files modified: {stats.files_modified}")
    print(f"__type_args__ in call nodes migrated: {stats.type_args_in_call}")
    print(f"__type_args__ in standalone messageCreation removed: {stats.type_args_standalone}")
    print(f"std.is/std.as type fields migrated: {stats.is_as_migrated}")

    if modified_files:
        print(f"\nModified files:")
        for f in modified_files:
            print(f"  {f}")


# ---------------------------------------------------------------------------
# Tests for the type parser
# ---------------------------------------------------------------------------

def test_parser():
    """Quick self-test for the type string parser."""
    # Simple types
    assert parse_type_string("int") == {"name": "int"}
    assert parse_type_string("String") == {"name": "String"}
    assert parse_type_string("void") == {"name": "void"}

    # Nullable
    assert parse_type_string("int?") == {"name": "int", "nullable": True}

    # Generic with one arg
    assert parse_type_string("Box<int>") == {"name": "Box", "typeArgs": [{"name": "int"}]}

    # Generic with two args
    assert parse_type_string("Map<String, int>") == {
        "name": "Map",
        "typeArgs": [{"name": "String"}, {"name": "int"}]
    }

    # Nested generic
    assert parse_type_string("List<Map<String, int>>") == {
        "name": "List",
        "typeArgs": [{"name": "Map", "typeArgs": [{"name": "String"}, {"name": "int"}]}]
    }

    # Module-qualified
    assert parse_type_string("main:Box") == {"name": "main:Box"}

    # Nullable generic
    assert parse_type_string("List<int>?") == {
        "name": "List", "typeArgs": [{"name": "int"}], "nullable": True
    }

    # __type_args__ string format
    assert parse_type_args_string("<int>") == [{"name": "int"}]
    assert parse_type_args_string("<int, String>") == [{"name": "int"}, {"name": "String"}]
    assert parse_type_args_string("<List<int>>") == [
        {"name": "List", "typeArgs": [{"name": "int"}]}
    ]
    assert parse_type_args_string("<Map<String, List<int>>>") == [
        {"name": "Map", "typeArgs": [{"name": "String"}, {"name": "List", "typeArgs": [{"name": "int"}]}]}
    ]

    # clean_type_ref
    assert clean_type_ref({"name": "int", "nullable": False, "typeArgs": []}) == {"name": "int"}
    assert clean_type_ref({"name": "int", "nullable": True}) == {"name": "int", "nullable": True}

    print("All parser tests passed!")


if __name__ == "__main__":
    if "--test" in sys.argv:
        test_parser()
    else:
        test_parser()  # Always run tests first
        print()
        main()
