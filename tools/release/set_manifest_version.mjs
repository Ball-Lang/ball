// Writes a computed semantic-release version into a non-npm package manifest,
// invoked from @semantic-release/exec's `prepareCmd` (see the .github/release/*
// configs). npm packages don't use this — @semantic-release/npm bumps their
// package.json directly.
//
// Formats:
//   --format=pubspec         Dart: replaces the top-level `version:` line in a
//                            pubspec.yaml. semantic-release emits a pure X.Y.Z,
//                            so any prior `+build` metadata (e.g. 0.3.0+6) is
//                            intentionally dropped going forward.
//   --format=cargo-workspace Rust (LOCKSTEP): in rust/Cargo.toml, rewrites
//                            `[workspace.package] version` AND every local
//                            path-dependency `version = "..."` pin under
//                            `[workspace.dependencies]` so all crates stay in
//                            lockstep and remain publishable (cargo publish
//                            requires each path dep to carry a version that
//                            resolves on crates.io). Keyed on `path` + `version`,
//                            NOT on hardcoded crate names, so it survives the
//                            ball-* -> ball-lang-* rename (and any future rename).
//                            De-lockstep to per-crate versions is a documented
//                            later follow-up.
//
// Usage:
//   node set_manifest_version.mjs --format=pubspec --file=dart/engine/pubspec.yaml --version=0.3.1
//   node set_manifest_version.mjs --format=cargo-workspace --file=rust/Cargo.toml --version=0.2.0

import { readFileSync, writeFileSync } from 'node:fs';

function parseArgs(argv) {
  const args = {};
  for (const a of argv) {
    const m = /^--([^=]+)=(.*)$/.exec(a);
    if (m) args[m[1]] = m[2];
  }
  return args;
}

const { format, file, version } = parseArgs(process.argv.slice(2));
if (!format || !file || !version) {
  console.error(
    'set_manifest_version: require --format=<pubspec|cargo-workspace> --file=<path> --version=<x.y.z>',
  );
  process.exit(1);
}
if (!/^\d+\.\d+\.\d+/.test(version)) {
  console.error(`set_manifest_version: invalid version "${version}"`);
  process.exit(1);
}

const original = readFileSync(file, 'utf8');
let updated;

if (format === 'pubspec') {
  // Only the top-level `version:` key (column 0), never a nested one.
  if (!/^version:\s*\S+/m.test(original)) {
    console.error(`set_manifest_version: no top-level "version:" in ${file}`);
    process.exit(1);
  }
  updated = original.replace(/^version:\s*\S+.*$/m, `version: ${version}`);
} else if (format === 'cargo-workspace') {
  let section = '';
  updated = original
    .split('\n')
    .map((line) => {
      const header = /^\s*\[([^\]]+)\]\s*$/.exec(line);
      if (header) {
        section = header[1];
        return line;
      }
      if (section === 'workspace.package' && /^\s*version\s*=/.test(line)) {
        return line.replace(/version\s*=\s*"[^"]*"/, `version = "${version}"`);
      }
      // Local sibling crates under [workspace.dependencies] carry BOTH a `path`
      // and a `version` (cargo publish requires the version pin). Bump those in
      // lockstep so each path dep's crates.io-resolvable version tracks the
      // workspace version. Match on `path` + `version` rather than crate names
      // so this survives the ball-* -> ball-lang-* rename; external deps
      // (prost/indexmap/syn/...) have no `path` and are left untouched.
      if (
        section === 'workspace.dependencies' &&
        /\bpath\s*=/.test(line) &&
        /\bversion\s*=\s*"[^"]*"/.test(line)
      ) {
        return line.replace(/version\s*=\s*"[^"]*"/, `version = "${version}"`);
      }
      return line;
    })
    .join('\n');
} else {
  console.error(`set_manifest_version: unknown --format "${format}"`);
  process.exit(1);
}

if (updated === original) {
  console.error(`set_manifest_version: no change written to ${file} (pattern not found?)`);
  process.exit(1);
}
writeFileSync(file, updated);
console.log(`set_manifest_version: ${file} -> ${version} (${format})`);
