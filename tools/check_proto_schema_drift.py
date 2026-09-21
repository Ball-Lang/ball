#!/usr/bin/env python3
"""Fails when `ball.schema.json` has drifted from `proto/ball/v1/ball.proto`.

`ball.schema.json` is the hand-maintained JSON Schema (Draft 2020-12) mirror of
the protobuf-JSON wire format, for JSON-only (non-protobuf) implementers, and
`docs/BALL_JSON_SPEC.md` points machine-readable outputs at it by `$defs` ref
(`ball audit --output` -> `#/$defs/BallCapabilityReport`). Every `$defs` object
sets `additionalProperties: false`, so a field added to `ball.proto` WITHOUT the
matching schema edit does not merely go undocumented — it makes the schema
actively REJECT the tool output the repo itself emits (issue #609 added
`CallSite.resolved_module` and the schema kept rejecting `resolvedModule`).

`scripts/validate_ball_schema.py` cannot see that class of drift: it validates
`ball.v1.Program` documents from the conformance/examples corpus, and no corpus
file is a `BallCapabilityReport`, a `BallManifest` or a `BallLockfile`. This
script closes the hole from the other side — structurally, for EVERY message in
`ball.proto`, corpus or no corpus.

Source of truth is `proto/ball/v1/ball.proto` itself (AGENTS.md: "keep in sync
with `ball.proto`"), parsed here with a deliberately STRICT reader: any line
inside a message/enum body that is not a comment, a field, a nested `oneof`, or
a brace is a hard error rather than a silently skipped line — a parser that can
quietly miss a field would be a fake-green gate.

Usage:
    python tools/check_proto_schema_drift.py [--root DIR] [--verbose]

Exit codes: 0 = in sync, 1 = drift, 2 = usage/parse error. `--root` points the
checker at a scratch copy of the repo and exists for
tools/test/test_check_proto_schema_drift.py, which breaks one thing at a time
and asserts this script fires.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
PROTO_REL = Path("proto") / "ball" / "v1" / "ball.proto"
SCHEMA_REL = Path("ball.schema.json")

# Positive floors — MEASURED on 2026-09-14 against ball.proto, not aspirational.
# Exit status alone cannot tell "everything matched" from "nothing was read"
# (a renamed proto, a parser that stopped recognising `message`, a schema whose
# $defs vanished), so a run that compares fewer than this many things FAILS.
# proto is append-only (`buf breaking` guards it), so these only ever rise.
MIN_MESSAGES = 34
MIN_FIELDS = 153
MIN_ENUMS = 2

# proto scalar -> the schema shape this repo mirrors it with. proto3 JSON maps
# 64-bit ints to strings and bytes to base64, which is why those two are $refs
# to the shared helper defs rather than bare types.
SCALAR_SHAPES: dict[str, dict] = {
    "string": {"type": "string"},
    "bool": {"type": "boolean"},
    "bytes": {"$ref": "#/$defs/Bytes"},
    "int32": {"$ref": "#/$defs/Int32"},
    "int64": {"$ref": "#/$defs/Int64String"},
    "double": {"$ref": "#/$defs/Double"},
}

# google.protobuf types whose JSON form this schema models under a prefixed def
# name (`Struct` -> `GoogleStruct`), because the bare name would collide with a
# ball.v1 message or read as one. Everything else imported from descriptor.proto
# keeps its own name (`DescriptorProto`, `EnumDescriptorProto`, ...).
WELL_KNOWN_DEF_NAMES = {
    "google.protobuf.Struct": "GoogleStruct",
    "google.protobuf.Value": "GoogleValue",
    "google.protobuf.ListValue": "GoogleListValue",
}

_FIELD_RE = re.compile(
    r"^(?P<repeated>repeated\s+)?"
    r"(?P<type>map<\s*[A-Za-z0-9_.]+\s*,\s*[A-Za-z0-9_.]+\s*>|[A-Za-z0-9_.]+)"
    r"\s+(?P<name>[a-z][a-z0-9_]*)\s*=\s*(?P<number>\d+)\s*;$"
)
_MAP_RE = re.compile(r"^map<\s*(?P<key>[A-Za-z0-9_.]+)\s*,\s*(?P<value>[A-Za-z0-9_.]+)\s*>$")
_ENUM_VALUE_RE = re.compile(r"^(?P<name>[A-Z][A-Z0-9_]*)\s*=\s*(?P<number>\d+)\s*;$")
_MESSAGE_OPEN_RE = re.compile(r"^message\s+(?P<name>[A-Za-z_][A-Za-z0-9_]*)\s*\{$")
_ENUM_OPEN_RE = re.compile(r"^enum\s+(?P<name>[A-Za-z_][A-Za-z0-9_]*)\s*\{$")
_ONEOF_OPEN_RE = re.compile(r"^oneof\s+[a-z][a-z0-9_]*\s*\{$")
_TOP_LEVEL_RE = re.compile(r"^(syntax|package|import|option)\b.*;$")


class ProtoParseError(Exception):
    """A line the strict reader refuses to interpret. Never swallowed."""


class ProtoField:
    __slots__ = ("name", "json_name", "type", "repeated", "map_value_type")

    def __init__(self, name: str, type_: str, repeated: bool, map_value_type: str | None):
        self.name = name
        self.json_name = json_name_of(name)
        self.type = type_
        self.repeated = repeated
        self.map_value_type = map_value_type


def json_name_of(field_name: str) -> str:
    """protobuf's JSON name: lowerCamelCase, per the proto3 JSON mapping."""
    head, *rest = field_name.split("_")
    return head + "".join(part[:1].upper() + part[1:] for part in rest)


def strip_comment(line: str) -> str:
    """Drop a trailing `//` comment. ball.proto has no string literals in field
    declarations, so a naive split is exact here; a `//` inside a quoted string
    would be mis-handled, which is why parse_proto() rejects any `option` line
    inside a body rather than trying to read one."""
    idx = line.find("//")
    return line if idx < 0 else line[:idx]


def parse_proto(path: Path) -> tuple[dict[str, list[ProtoField]], dict[str, list[str]]]:
    messages: dict[str, list[ProtoField]] = {}
    enums: dict[str, list[str]] = {}

    # (kind, name) frames: "message", "enum", "oneof". ball.proto is flat apart
    # from oneof, but the reader tracks a real stack so a future nested message
    # fails loudly here instead of being attributed to its parent.
    stack: list[tuple[str, str]] = []

    for lineno, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
        line = strip_comment(raw).strip()
        if not line:
            continue

        def fail(why: str) -> ProtoParseError:
            return ProtoParseError(f"{path.name}:{lineno}: {why}: {raw.strip()!r}")

        if line == "}":
            if not stack:
                raise fail("unbalanced '}'")
            stack.pop()
            continue

        if not stack:
            if _TOP_LEVEL_RE.match(line):
                continue
            m = _MESSAGE_OPEN_RE.match(line)
            if m:
                name = m.group("name")
                if name in messages:
                    raise fail(f"duplicate message {name}")
                messages[name] = []
                stack.append(("message", name))
                continue
            m = _ENUM_OPEN_RE.match(line)
            if m:
                name = m.group("name")
                if name in enums:
                    raise fail(f"duplicate enum {name}")
                enums[name] = []
                stack.append(("enum", name))
                continue
            raise fail("unrecognised top-level declaration")

        kind, owner = stack[-1]
        if kind == "enum":
            m = _ENUM_VALUE_RE.match(line)
            if not m:
                raise fail(f"unrecognised line in enum {owner}")
            enums[owner].append(m.group("name"))
            continue

        # message or oneof body
        if _ONEOF_OPEN_RE.match(line):
            stack.append(("oneof", owner))
            continue

        m = _FIELD_RE.match(line)
        if not m:
            raise fail(f"unrecognised line in message {owner}")

        # A oneof frame carries its message's name, so its fields land on the
        # message — which is exactly how proto3 JSON renders them.
        message_name = owner if kind == "message" else stack[-1][1]
        type_ = m.group("type")
        map_match = _MAP_RE.match(type_)
        if map_match:
            if map_match.group("key") != "string":
                raise fail("only map<string, V> is mirrored by ball.schema.json")
            field = ProtoField(m.group("name"), "map", True, map_match.group("value"))
        else:
            field = ProtoField(m.group("name"), type_, bool(m.group("repeated")), None)
        messages[message_name].append(field)

    if stack:
        raise ProtoParseError(f"{path.name}: unterminated {stack[-1][0]} {stack[-1][1]!r}")
    return messages, enums


def def_name_for(type_: str) -> str:
    """The `$defs` name a non-scalar proto type is mirrored under."""
    if type_ in WELL_KNOWN_DEF_NAMES:
        return WELL_KNOWN_DEF_NAMES[type_]
    return type_.rsplit(".", 1)[-1]


def base_shape(type_: str) -> dict:
    if type_ in SCALAR_SHAPES:
        return SCALAR_SHAPES[type_]
    return {"$ref": "#/$defs/" + def_name_for(type_)}


def expected_shape(field: ProtoField) -> dict:
    if field.map_value_type is not None:
        return {"type": "object", "additionalProperties": base_shape(field.map_value_type)}
    if field.repeated:
        return {"type": "array", "items": base_shape(field.type)}
    return base_shape(field.type)


def structural(node: object) -> object:
    """A schema node with its prose stripped, so a doc edit is never drift."""
    if isinstance(node, dict):
        return {k: structural(v) for k, v in sorted(node.items()) if k != "description"}
    if isinstance(node, list):
        return [structural(v) for v in node]
    return node


def mirrors(want: object, got: object) -> bool:
    """True when `got` carries every keyword `want` mirrors, with equal values.

    Deliberately NOT plain equality: the schema is allowed to be STRICTER than
    the proto where the JSON form is narrower than `string` (ModuleImport's
    `integrity` adds a `pattern`, and `@type` a fixed suffix). It is never
    allowed to contradict or drop what the proto declares, which is what a
    missing or mistyped property looks like here.
    """
    if isinstance(want, dict):
        if not isinstance(got, dict):
            return False
        return all(k in got and mirrors(v, got[k]) for k, v in want.items())
    return want == got


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--root", default=str(REPO_ROOT), help="repo root to check (default: this checkout)"
    )
    parser.add_argument(
        "--verbose", "-v", action="store_true", help="print every message as it is compared"
    )
    args = parser.parse_args()

    root = Path(args.root).resolve()
    proto_path = root / PROTO_REL
    schema_path = root / SCHEMA_REL

    if not proto_path.is_file():
        print(f"error: {proto_path} not found", file=sys.stderr)
        return 2
    if not schema_path.is_file():
        print(f"error: {schema_path} not found", file=sys.stderr)
        return 2

    try:
        messages, enums = parse_proto(proto_path)
    except ProtoParseError as exc:
        print(f"error: {exc}", file=sys.stderr)
        print(
            "hint: this reader is strict on purpose — teach it the new syntax "
            "rather than letting a field slip past the drift check.",
            file=sys.stderr,
        )
        return 2

    schema = json.loads(schema_path.read_text(encoding="utf-8"))
    defs = schema.get("$defs")
    if not isinstance(defs, dict):
        print("error: ball.schema.json has no $defs object", file=sys.stderr)
        return 2

    failures: list[str] = []
    field_count = 0

    for name, fields in sorted(messages.items()):
        field_count += len(fields)
        entry = defs.get(name)
        if entry is None:
            failures.append(f"{name}: message has no $defs/{name} in ball.schema.json")
            continue
        props = entry.get("properties")
        if not isinstance(props, dict):
            failures.append(f"{name}: $defs/{name} has no properties object")
            continue

        # `@type` is the google.protobuf.Any envelope key, a JSON-only affordance
        # with no proto field behind it. Every other property must be a field.
        declared = set(props) - {"@type"}
        expected_names = {f.json_name for f in fields}
        for missing in sorted(expected_names - declared):
            failures.append(
                f"{name}.{missing}: declared in ball.proto, missing from $defs/{name} "
                f"(which sets additionalProperties:false, so the schema REJECTS it)"
            )
        for extra in sorted(declared - expected_names):
            failures.append(f"{name}.{extra}: in $defs/{name} but not in ball.proto")

        for field in fields:
            prop = props.get(field.json_name)
            if prop is None:
                continue  # already reported as missing
            want = structural(expected_shape(field))
            got = structural(prop)
            if not mirrors(want, got):
                failures.append(
                    f"{name}.{field.json_name}: shape mismatch — ball.proto requires "
                    f"{json.dumps(want, sort_keys=True)}, ball.schema.json says "
                    f"{json.dumps(got, sort_keys=True)}"
                )
        if args.verbose:
            print(f"OK    {name} ({len(fields)} fields)")

    for name, values in sorted(enums.items()):
        entry = defs.get(name)
        if entry is None:
            failures.append(f"{name}: enum has no $defs/{name} in ball.schema.json")
            continue
        want = {"type": "string", "enum": values}
        got = structural(entry)
        if not mirrors(want, got):
            failures.append(
                f"{name}: enum mismatch — ball.proto says "
                f"{json.dumps(want, sort_keys=True)}, ball.schema.json says "
                f"{json.dumps(got, sort_keys=True)}"
            )
        elif args.verbose:
            print(f"OK    {name} ({len(values)} values)")

    print(
        f"compared {len(messages)} messages, {field_count} fields, "
        f"{len(enums)} enums from {PROTO_REL.as_posix()}"
    )

    if len(messages) < MIN_MESSAGES or field_count < MIN_FIELDS or len(enums) < MIN_ENUMS:
        print(
            f"error: read fewer declarations than the measured floor "
            f"({MIN_MESSAGES} messages / {MIN_FIELDS} fields / {MIN_ENUMS} enums) — "
            f"the reader found nothing to compare, which is not a pass",
            file=sys.stderr,
        )
        return 2

    if failures:
        print(f"\n{len(failures)} DRIFT(S) between ball.proto and ball.schema.json:", file=sys.stderr)
        for failure in failures:
            print(f"  {failure}", file=sys.stderr)
        print(
            "\nfix: edit ball.schema.json to mirror ball.proto, then re-run "
            "`python scripts/validate_ball_schema.py`.",
            file=sys.stderr,
        )
        return 1

    print("ball.schema.json is in sync with ball.proto.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
