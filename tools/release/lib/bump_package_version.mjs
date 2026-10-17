// Pure helper: rewrite ONLY the top-level "version" field of a package.json's
// raw text, byte-for-byte otherwise (issue #755).
//
// WHY A REGEX AND NOT JSON.parse/stringify: @semantic-release/npm's prepare
// step shells out to `npm version <v> --no-git-tag-version --allow-same-version`
// (lib/prepare.js upstream), which preserves the file's original formatting
// (indentation, key order, trailing newline). A JSON.parse → JSON.stringify
// round-trip would normalize all of that and produce an unrelated diff on
// every release. A targeted regex against the FIRST `"version": "…"` line
// matches npm's own behavior (and this repo's four ts/*/package.json files
// each declare "version" exactly once, at the top level — "version" never
// appears as a dependency key) without touching anything else in the file.
//
// @param {string} packageJsonText - the current package.json text.
// @param {string} version - the new version string (e.g. "1.73.0").
// @returns {string} the rewritten text.
// @throws {Error} if no top-level "version" field is found (fail loud).
const VERSION_LINE = /^(\s*"version"\s*:\s*")[^"]*("\s*,?\s*)$/m;

export function bumpPackageJsonVersion(packageJsonText, version) {
  if (!VERSION_LINE.test(packageJsonText)) {
    throw new Error('bumpPackageJsonVersion: no top-level "version" field found');
  }
  return packageJsonText.replace(VERSION_LINE, (_match, prefix, suffix) => `${prefix}${version}${suffix}`);
}
