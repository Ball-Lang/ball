/**
 * Self-describing ball-file envelope helper for compiler tests.
 *
 * Ball files (`.ball.json`) are the proto3-JSON form of a
 * `google.protobuf.Any` wrapping a `Program` (or `Module`):
 * `{"@type": "type.googleapis.com/ball.v1.Program", <message fields…>}`.
 *
 * The compiler consumes the raw proto3-JSON tree, so unwrapping just validates
 * `@type` and strips it, returning the message body unchanged. Mirrors the
 * canonical `@ball-lang/shared` / `dart/shared/lib/ball_file.dart` behavior;
 * duplicated here because `@ball-lang/compiler` has no `@ball-lang/shared` dep.
 */

export function unwrapBallFile(json: any): any {
  if (json === null || typeof json !== "object" || Array.isArray(json)) {
    return json;
  }
  const type = json["@type"];
  if (type === undefined) return json; // already unwrapped
  const isProgram = typeof type === "string" && type.endsWith("/ball.v1.Program");
  const isModule = typeof type === "string" && type.endsWith("/ball.v1.Module");
  if (!isProgram && !isModule) {
    throw new Error(`unknown ball file @type: ${JSON.stringify(type)}`);
  }
  const body: Record<string, unknown> = {};
  for (const [k, v] of Object.entries(json)) {
    if (k === "@type") continue;
    body[k] = v;
  }
  return body;
}
