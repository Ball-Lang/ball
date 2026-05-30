/**
 * Self-describing ball-file envelope helpers (engine-local copy).
 *
 * A ball file on disk (`.ball.json`) is the proto3-JSON representation of a
 * `google.protobuf.Any` wrapping exactly one top-level message — a `Program`
 * or `Module`. The contained type is carried by the Any type URL, which in
 * proto3 JSON is the `@type` field:
 * `{"@type": "type.googleapis.com/ball.v1.Program", <message fields…>}`.
 *
 * The engine operates on the raw proto3-JSON tree (not a decoded protobuf-es
 * Message), so unwrapping here just validates `@type` and strips it, returning
 * the message body unchanged. This is the canonical
 * `@ball-lang/shared`/`dart/shared/lib/ball_file.dart` behavior; it lives here
 * too because `@ball-lang/engine` has no dependency on `@ball-lang/shared`.
 */

function isProgramUrl(url: string): boolean {
  return url.endsWith('/ball.v1.Program');
}
function isModuleUrl(url: string): boolean {
  return url.endsWith('/ball.v1.Module');
}

/**
 * If `json` is a self-describing Any envelope (`@type` present), validate the
 * type URL and return the message body with `@type` stripped. If it is a plain
 * object without `@type` (an already-unwrapped Program/Module passed by a
 * caller), return it unchanged.
 *
 * Throws if `@type` is present but unrecognized.
 */
export function unwrapBallFile(json: any): any {
  if (json === null || typeof json !== 'object' || Array.isArray(json)) {
    return json;
  }
  const type = json['@type'];
  if (type === undefined) {
    // Already unwrapped — keep supporting bare Program/Module objects.
    return json;
  }
  if (typeof type !== 'string' || (!isProgramUrl(type) && !isModuleUrl(type))) {
    throw new Error(`unknown ball file @type: ${JSON.stringify(type)}`);
  }
  const body: Record<string, unknown> = {};
  for (const [k, v] of Object.entries(json)) {
    if (k === '@type') continue;
    body[k] = v;
  }
  return body;
}
