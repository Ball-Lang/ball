/**
 * Self-describing ball-file envelope (TypeScript).
 *
 * A ball file on disk (`.ball.json` or `.ball.bin`) is a serialized
 * `google.protobuf.Any` wrapping exactly one top-level message — today a
 * {@link Program} or a {@link Module}. Readers never guess the contained
 * type: it is carried explicitly by the Any type URL, which in proto3 JSON
 * is the `@type` field. New top-level types can be added without changing
 * any reader's discrimination logic.
 *
 * Binary form uses the real `google.protobuf.Any` (type_url + value bytes).
 * JSON form is the proto3-JSON representation of an Any:
 * `{"@type": "type.googleapis.com/ball.v1.Program", <message fields…>}` — so
 * it round-trips through the message's own proto3-JSON codec plus the one
 * `@type` key, with no type registry required.
 *
 * This mirrors `dart/shared/lib/ball_file.dart`.
 */

import {
  fromJson,
  toJson,
  fromBinary,
  toBinary,
  type JsonValue,
  type JsonObject,
} from "@bufbuild/protobuf";
import { anyUnpack, AnySchema, type Any } from "@bufbuild/protobuf/wkt";
import {
  ProgramSchema,
  ModuleSchema,
  type Program,
  type Module,
} from "../gen/ball/v1/ball_pb.js";

const TYPE_URL_PREFIX = "type.googleapis.com";
export const PROGRAM_TYPE_URL = `${TYPE_URL_PREFIX}/ball.v1.Program`;
export const MODULE_TYPE_URL = `${TYPE_URL_PREFIX}/ball.v1.Module`;

/** Thrown when a ball file is not a recognized self-describing envelope. */
export class BallFileFormatError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "BallFileFormatError";
  }
}

/** The decoded contents of a ball file: exactly one top-level message. */
export type BallFile =
  | { kind: "program"; program: Program }
  | { kind: "module"; module: Module };

function isProgramUrl(url: string): boolean {
  return url.endsWith("/ball.v1.Program");
}
function isModuleUrl(url: string): boolean {
  return url.endsWith("/ball.v1.Module");
}

// ── Plain proto3-JSON unwrap (no decode) ──────────────────────────────────

/**
 * Validates the self-describing envelope of a parsed ball-file JSON object and
 * returns its message body as a plain proto3-JSON object — the `@type` key
 * stripped, everything else untouched.
 *
 * Use this on the file LOAD boundary when the consumer operates on the raw
 * proto3-JSON tree (e.g. the tree-walking engine or the string-emitting
 * compiler) rather than on a decoded protobuf-es `Message`. The returned
 * object keeps the exact same field names/shape as the wrapped message, so it
 * is a drop-in replacement for what `JSON.parse` used to yield before files
 * became Any-wrapped.
 *
 * Throws {@link BallFileFormatError} if `@type` is missing or unknown.
 */
export function unwrapBallFileJson(json: unknown): JsonObject {
  if (json === null || typeof json !== "object" || Array.isArray(json)) {
    throw new BallFileFormatError("ball file JSON must be an object");
  }
  const obj = json as Record<string, JsonValue>;
  const type = obj["@type"];
  if (typeof type !== "string") {
    throw new BallFileFormatError(
      'ball file JSON is not self-describing: missing "@type" ' +
        "(expected a google.protobuf.Any envelope)",
    );
  }
  if (!isProgramUrl(type) && !isModuleUrl(type)) {
    throw new BallFileFormatError(`unknown ball file @type: "${type}"`);
  }
  const body: JsonObject = {};
  for (const [k, v] of Object.entries(obj)) {
    if (k === "@type") continue;
    body[k] = v;
  }
  return body;
}

// ── Decode (typed protobuf-es Message) ────────────────────────────────────

/** Decodes a proto3-JSON ball file (an Any with an `@type` field). */
export function decodeBallFileJson(json: unknown): BallFile {
  if (json === null || typeof json !== "object" || Array.isArray(json)) {
    throw new BallFileFormatError("ball file JSON must be an object");
  }
  const obj = json as Record<string, JsonValue>;
  const type = obj["@type"];
  if (typeof type !== "string") {
    throw new BallFileFormatError(
      'ball file JSON is not self-describing: missing "@type" ' +
        "(expected a google.protobuf.Any envelope)",
    );
  }
  const body = unwrapBallFileJson(json);
  if (isProgramUrl(type)) {
    return { kind: "program", program: fromJson(ProgramSchema, body) };
  }
  if (isModuleUrl(type)) {
    return { kind: "module", module: fromJson(ModuleSchema, body) };
  }
  // Unreachable: unwrapBallFileJson above already runs this same check and
  // throws first if neither matches. Kept for exhaustiveness (TS can't see
  // that guarantee across the function call).
  throw new BallFileFormatError(`unknown ball file @type: "${type}"`);
}

/** Decodes a {@link Program} from a ball file JSON, or throws if it wraps a Module. */
export function decodeProgramJson(json: unknown): Program {
  const file = decodeBallFileJson(json);
  if (file.kind === "program") return file.program;
  throw new BallFileFormatError(
    "expected a Program ball file but got a Module",
  );
}

/** Decodes a {@link Module} from a ball file JSON, or throws if it wraps a Program. */
export function decodeModuleJson(json: unknown): Module {
  const file = decodeBallFileJson(json);
  if (file.kind === "module") return file.module;
  throw new BallFileFormatError(
    "expected a Module ball file but got a Program",
  );
}

/** Decodes a binary ball file (serialized `google.protobuf.Any`). */
export function decodeBallFileBinary(bytes: Uint8Array): BallFile {
  const any: Any = fromBinary(AnySchema, bytes);
  if (isProgramUrl(any.typeUrl)) {
    // Unreachable: anyUnpack only returns undefined on a typeUrl mismatch
    // (already excluded by isProgramUrl), and fromBinary throws (verified
    // empirically) rather than returning undefined on corrupt bytes.
    const program = anyUnpack(any, ProgramSchema);
    if (program === undefined) {
      throw new BallFileFormatError(
        `could not unpack Program from Any (typeUrl "${any.typeUrl}")`,
      );
    }
    return { kind: "program", program };
  }
  if (isModuleUrl(any.typeUrl)) {
    // See the identical reasoning on the Program branch above.
    const module = anyUnpack(any, ModuleSchema);
    if (module === undefined) {
      throw new BallFileFormatError(
        `could not unpack Module from Any (typeUrl "${any.typeUrl}")`,
      );
    }
    return { kind: "module", module };
  }
  throw new BallFileFormatError(
    `unknown ball file type URL: "${any.typeUrl}"`,
  );
}

/** Decodes a {@link Program} from a binary ball file, or throws if it wraps a Module. */
export function decodeProgramBinary(bytes: Uint8Array): Program {
  const file = decodeBallFileBinary(bytes);
  if (file.kind === "program") return file.program;
  throw new BallFileFormatError(
    "expected a Program ball file but got a Module",
  );
}

/** Decodes a {@link Module} from a binary ball file, or throws if it wraps a Program. */
export function decodeModuleBinary(bytes: Uint8Array): Module {
  const file = decodeBallFileBinary(bytes);
  if (file.kind === "module") return file.module;
  throw new BallFileFormatError(
    "expected a Module ball file but got a Program",
  );
}

// ── Encode ─────────────────────────────────────────────────────────────────

/**
 * Encodes a {@link Program} as a proto3-JSON ball file: the message's own
 * proto3 JSON with the Any `@type` key prepended.
 */
export function encodeProgramJson(program: Program): JsonObject {
  const body = toJson(ProgramSchema, program) as JsonObject;
  return { "@type": PROGRAM_TYPE_URL, ...body };
}

/**
 * Encodes a {@link Module} as a proto3-JSON ball file: the message's own
 * proto3 JSON with the Any `@type` key prepended.
 */
export function encodeModuleJson(module: Module): JsonObject {
  const body = toJson(ModuleSchema, module) as JsonObject;
  return { "@type": MODULE_TYPE_URL, ...body };
}

/** Encodes a {@link Program} as a binary ball file (a serialized `google.protobuf.Any`). */
export function encodeProgramBinary(program: Program): Uint8Array {
  const value = toBinary(ProgramSchema, program);
  const any: Any = { $typeName: "google.protobuf.Any", typeUrl: PROGRAM_TYPE_URL, value };
  return toBinary(AnySchema, any);
}

/** Encodes a {@link Module} as a binary ball file (a serialized `google.protobuf.Any`). */
export function encodeModuleBinary(module: Module): Uint8Array {
  const value = toBinary(ModuleSchema, module);
  const any: Any = { $typeName: "google.protobuf.Any", typeUrl: MODULE_TYPE_URL, value };
  return toBinary(AnySchema, any);
}
