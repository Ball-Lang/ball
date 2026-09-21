/// FIELD-NAME signature gate for the std module builders (issue #771).
///
/// The closed-set ladder so far compares **function names**:
///
///   * `std_routed_declarations_test.dart` (#505) — declared ⊆ routed;
///   * `capability_table_closed_set_test.dart` (#686) — declared ⊆ keyed;
///   * `std_reverse_closed_set_test.dart` (#702) — dispatched/keyed/executed ⊆
///     declared.
///
/// Every one of those three, and the C#/Rust mirrors
/// (`csharp/shared/test/StdModuleBuilderTests.cs`,
/// `rust/shared/src/std_dart_parity.rs`), compares a NAME — and, at most, an
/// `outputType`. None of them looks inside a `TypeDefinition`'s `field[]`. So a
/// declaration such as
///
/// ```dart
/// _type('ListGenerateInput', [_exprField('len', 1), _exprField('generator', 2)])
/// ```
///
/// passes the whole suite: `std.list_generate` is declared, dispatched, keyed
/// and executed. It is also silently broken on every target, because
/// `dart/engine/lib/engine_std.dart`'s `_stdListGenerate` reads
/// `m['length'] ?? m['count'] ?? m['arg0']` and will never see a field spelled
/// `len`. No crash, no diagnostic, no gate — just a wrong runtime value for
/// every caller (issue #771).
///
/// This file is the next rung: it compares the FIELD NAMES a std base
/// function's declared input `TypeDefinition` carries against the field names
/// the Dart reference engine and the Dart compiler actually read for that
/// function, in both directions.
///
/// ### The two directions, and why their scopes differ
///
/// **A — declared ⊆ read** (`declaredNeverRead`). Every field a std input type
/// declares must be read by name somewhere on the Dart handling path for at
/// least one function that declares that type. This is the direction the #771
/// example lives in, and it is checked against the union of the ENGINE and the
/// COMPILER: a field can legitimately be meaningful to only one of them
/// (`ForInInput.variable_type` and `TypedListInput.type_args` are compile-time
/// only; `IfInput.case_pattern` is read by the compiler's pattern lowering).
///
/// **B — read ⊆ declared** (`readNeverDeclared`). Every key the engine's EAGER
/// std dispatch handler reads off its input message must be declared by a type
/// of that same module, named in the function's own description as an accepted
/// alternative spelling, or be part of the universal call convention
/// ([_callConventionKeys] / `arg0`, `arg1`, …). Its scope is deliberately
/// narrower than A's — the `_buildStdDispatch()` handler and the helpers it
/// calls — because the compiler's shared emit helpers
/// (`_methodCall`, `_binOp`, …) read generic argument keys (`receiver`, `arg`,
/// `separator`) that belong to the emitter's own calling convention rather than
/// to any one function's input descriptor. Widening B to them would report
/// dozens of non-findings, and a gate that cries wolf gets weakened.
///
/// `dart/shared/lib/std.dart` already states the convention this direction
/// enforces: "alternative spellings each handler also accepts are named in the
/// FUNCTION description rather than declared as extra fields, so the descriptor
/// stays the canonical shape." Before #771 nothing checked it, so several
/// handlers grew alias reads their description never mentioned and no target
/// could discover.
///
/// ### How the read set is derived
///
/// Nothing here is a hand-maintained expectation table — that would only prove
/// that two copies of the same list agree. The read set is PARSED out of the
/// Dart sources, the same shape `std_reverse_closed_set_test.dart` uses to read
/// the engine's dispatch map (and for the same reason: `ball_base` is the
/// bottom of the Dart dependency graph, so it cannot import `ball_engine` or
/// `ball_compiler`).
///
/// For a function `fn` the parser resolves an ENTRY REGION — the
/// `_buildStdDispatch()` map entry, the lazy `case 'fn':` arms in the engine,
/// and the `'fn' => …` arms of the compiler's base-call switches — then expands
/// it transitively through the private members those regions name, to a bounded
/// depth. Inside that region a READ is one of:
///
///   * `v['key']`, where `v` is a local bound from `_stdAsMap` / `_asMap` /
///     `_lazyFields` / `_extractFields` / `_messageFields`, or a parameter
///     declared `Map<String, …>` (the compiler's `Map<String, Expression> f`);
///   * `_anyHelper(v, 'key', …)` — any private helper whose FIRST argument is
///     that variable and whose SECOND is a string literal, e.g.
///     `_extractField(i, 'type')`, `_stringFieldValue(f, 'method')`,
///     `_concurrencyHandle(i, 'mutex', …)`. Derived from the argument SHAPE,
///     never from a list of blessed helper names;
///   * `<something>.name == 'key'` — the shape the lazy `map_create` evaluator
///     and the compiler's `typed_list` lowering use to pick fields off a
///     `MessageCreation` directly.
///
/// Comments are stripped before any of that: a dispatch entry whose comment
/// merely MENTIONS `_evalCall` must not drag that method's unrelated `'self'`
/// reads into the region.
///
/// Every population below carries a POSITIVE FLOOR, because each is a parse: a
/// regex that stops matching would otherwise turn every assertion vacuous and
/// the suite would pass while checking nothing.
@TestOn('vm')
library;

import 'dart:io';

import 'package:ball_base/ball_base.dart'
    show
        Module,
        buildStdCollectionsModule,
        buildStdConcurrencyModule,
        buildStdConvertModule,
        buildStdFsModule,
        buildStdIoModule,
        buildStdMemoryModule,
        buildStdModule,
        buildStdTimeModule;
import 'package:test/test.dart';

// ---------------------------------------------------------------------------
// Sources
// ---------------------------------------------------------------------------

/// Engine sources that make up the Dart reference engine's handling path.
const _engineSources = <String>[
  'dart/engine/lib/engine_std.dart',
  'dart/engine/lib/engine_eval.dart',
  'dart/engine/lib/engine_control_flow.dart',
  'dart/engine/lib/engine_invocation.dart',
  'dart/engine/lib/engine_types.dart',
  'dart/engine/lib/engine.dart',
];

/// Compiler sources. `_compileBaseCall` and its per-module siblings
/// (`_compileCollectionsCall`, `_compileIoCall`, …) all dispatch with
/// `'name' => _compileX(f)` arms over a `Map<String, Expression> f`.
const _compilerSources = <String>['dart/compiler/lib/compiler.dart'];

/// Locates the repo root, tolerating whichever directory the suite is launched
/// from (package dir, repo root, sibling package).
Directory _repoRoot() {
  for (final base in ['.', '..', '../..', '../../..']) {
    if (Directory('$base/tests/conformance').existsSync() &&
        File('$base/${_engineSources.first}').existsSync() &&
        File('$base/${_compilerSources.first}').existsSync()) {
      return Directory(base);
    }
  }
  throw StateError(
    'could not locate the repo root from ${Directory.current.path}',
  );
}

/// Removes `//` and `/* */` comments while leaving string literals (and their
/// byte offsets' relative order) intact.
///
/// Load-bearing, not cosmetic: dispatch entries and handler bodies carry prose
/// that names other members and quotes other field names — e.g.
/// `// Labels (handled lazily in _evalCall)` would otherwise pull the whole of
/// `_evalCall` into the `labeled` region, and `// Support both 'entries' and
/// 'entry' formats` would count as a read of both.
String stripDartComments(String src) {
  final out = StringBuffer();
  var i = 0;
  while (i < src.length) {
    final c = src[i];
    // Raw strings: no escapes inside.
    if (c == 'r' &&
        i + 1 < src.length &&
        (src[i + 1] == "'" || src[i + 1] == '"')) {
      final quote = src[i + 1];
      out.write(c);
      out.write(quote);
      i += 2;
      while (i < src.length && src[i] != quote && src[i] != '\n') {
        out.write(src[i]);
        i++;
      }
      if (i < src.length) {
        out.write(src[i]);
        i++;
      }
      continue;
    }
    if (c == "'" || c == '"') {
      final triple = src.startsWith(c * 3, i);
      final delim = triple ? c * 3 : c;
      out.write(delim);
      i += delim.length;
      while (i < src.length) {
        if (src[i] == r'\') {
          out.write(src[i]);
          if (i + 1 < src.length) out.write(src[i + 1]);
          i += 2;
          continue;
        }
        if (src.startsWith(delim, i)) {
          out.write(delim);
          i += delim.length;
          break;
        }
        // An unterminated single-quoted literal cannot span a newline.
        if (!triple && src[i] == '\n') break;
        out.write(src[i]);
        i++;
      }
      continue;
    }
    if (src.startsWith('//', i)) {
      while (i < src.length && src[i] != '\n') {
        i++;
      }
      continue;
    }
    if (src.startsWith('/*', i)) {
      final end = src.indexOf('*/', i + 2);
      i = end < 0 ? src.length : end + 2;
      continue;
    }
    out.write(c);
    i++;
  }
  return out.toString();
}

// ---------------------------------------------------------------------------
// Member index
// ---------------------------------------------------------------------------

/// A private member declaration: exactly two spaces of indentation (a member of
/// the top-level class/extension), a non-blank first character, and a
/// `_identifier(` somewhere on the declaration line.
final _memberDecl = RegExp(
  r'^  [^\s].*?\b(_[A-Za-z0-9_]+)\s*\(',
  multiLine: true,
);

/// Returns the member's source, from [start] through the end of its body —
/// a braced block, an `=>` expression, or a bare `;` declaration.
String _memberBody(String src, int start) {
  var i = src.indexOf('(', start);
  if (i < 0) return src.substring(start);
  var depth = 0;
  while (i < src.length) {
    if (src[i] == '(') {
      depth++;
    } else if (src[i] == ')') {
      depth--;
      if (depth == 0) break;
    }
    i++;
  }
  var k = i + 1;
  while (k < src.length) {
    if (src[k] == '{') {
      var d = 0;
      var p = k;
      while (p < src.length) {
        if (src[p] == '{') {
          d++;
        } else if (src[p] == '}') {
          d--;
          if (d == 0) return src.substring(start, p + 1);
        }
        p++;
      }
      return src.substring(start);
    }
    if (src.startsWith('=>', k)) {
      final end = src.indexOf(';', k);
      return src.substring(start, end < 0 ? src.length : end);
    }
    if (src[k] == ';') return src.substring(start, k);
    k++;
  }
  return src.substring(start);
}

/// Every private member of the given sources, keyed by name. The FIRST
/// declaration of a name wins; the engine and the compiler do not share private
/// member names on any path this gate resolves.
Map<String, String> indexMembers(Iterable<String> sources) {
  final out = <String, String>{};
  for (final src in sources) {
    for (final m in _memberDecl.allMatches(src)) {
      out.putIfAbsent(m.group(1)!, () => _memberBody(src, m.start));
    }
  }
  return out;
}

// ---------------------------------------------------------------------------
// Entry regions
// ---------------------------------------------------------------------------

/// Opening line of the engine's eager dispatch-table builder. Matched literally
/// so a rename fails the extraction (and therefore the floor) rather than
/// silently yielding an empty set.
const _dispatchSignature =
    'Map<String, FutureOr<Object?> Function(Object?)> _buildStdDispatch() {';

/// A top-level entry of that map literal — six spaces, a quoted identifier, a
/// colon. Nested closures indent deeper, so this reads dispatch keys only.
final _dispatchKey = RegExp(r"^      '([A-Za-z0-9_]+)':", multiLine: true);

/// A base-call arm of one of the compiler's `switch (call.function)`
/// EXPRESSIONS: six spaces, a quoted identifier, `=>`.
final _compilerArm = RegExp(r"^      '([A-Za-z0-9_]+)' =>", multiLine: true);

/// A `case 'name':` arm of a `switch` STATEMENT (the engine's lazy-construct
/// dispatch, and the compiler's statement-shaped lowerings).
final _caseArm = RegExp(r"case '([A-Za-z0-9_]+)':", multiLine: true);

/// The declaration line and input-map bindings of the member that ENCLOSES
/// [offset].
///
/// A switch arm is only part of a handler: the compiler writes
/// `final f = _extractFields(call);` once at the top of `_compileIoCall` and
/// then `'sleep_ms' => …_e(f['milliseconds']!)…` in the arm. Read in isolation
/// the arm has no binding for `f`, so its reads would be invisible. Only the
/// enclosing member's DECLARATION LINE and its binding statements come along —
/// never its whole body, which would drag in every sibling arm's reads.
String _enclosingBinds(String src, int offset) {
  var declStart = -1;
  for (final m in _memberDecl.allMatches(src)) {
    if (m.start > offset) break;
    declStart = m.start;
  }
  if (declStart < 0) return '';
  final body = _memberBody(src, declStart);
  if (declStart + body.length < offset) return '';
  final out = StringBuffer();
  final firstBrace = body.indexOf('{');
  out.writeln(firstBrace < 0 ? body : body.substring(0, firstBrace));
  for (final m in _bindLocal.allMatches(body)) {
    out.writeln(body.substring(m.start, m.end));
  }
  return out.toString();
}

/// Splits [text] at every [pattern] match, giving each match's captured name
/// the slice that runs to the next match, prefixed by the enclosing member's
/// bindings (see [_enclosingBinds]).
void _addSlices(
  Map<String, List<String>> into,
  String text,
  RegExp pattern, {
  int? cap,
}) {
  final ms = pattern.allMatches(text).toList();
  for (var i = 0; i < ms.length; i++) {
    final end = i + 1 < ms.length ? ms[i + 1].start : text.length;
    var slice = text.substring(ms[i].end, end);
    if (cap != null && slice.length > cap) slice = slice.substring(0, cap);
    into
        .putIfAbsent(ms[i].group(1)!, () => <String>[])
        .add('${_enclosingBinds(text, ms[i].start)}\n$slice');
  }
}

/// The `_buildStdDispatch()` map literal, sliced per dispatch key.
Map<String, String> eagerDispatchEntries(String engineStdSource) {
  final start = engineStdSource.indexOf(_dispatchSignature);
  if (start < 0) {
    throw StateError(
      '_buildStdDispatch() not found in engine_std.dart — its signature '
      'changed; update _dispatchSignature',
    );
  }
  final end = engineStdSource.indexOf('\n    };', start);
  if (end < 0) {
    throw StateError('could not find the end of the _buildStdDispatch() map');
  }
  final sliced = <String, List<String>>{};
  _addSlices(sliced, engineStdSource.substring(start, end), _dispatchKey);
  return sliced.map((k, v) => MapEntry(k, v.single));
}

/// A `case` arm is sliced to this many characters: enough to name the handler
/// it delegates to, short enough that a long arm cannot swallow its neighbours.
const _caseArmCap = 400;

/// Every entry region, per bare function name, across engine and compiler.
Map<String, List<String>> allEntryRegions({
  required Map<String, String> engineSources,
  required Map<String, String> compilerSources,
}) {
  final out = <String, List<String>>{};
  eagerDispatchEntries(
    engineSources[_engineSources.first]!,
  ).forEach((k, v) => out.putIfAbsent(k, () => <String>[]).add(v));
  for (final src in engineSources.values) {
    _addSlices(out, src, _caseArm, cap: _caseArmCap);
  }
  for (final src in compilerSources.values) {
    _addSlices(out, src, _compilerArm);
    _addSlices(out, src, _caseArm, cap: _caseArmCap);
  }
  return out;
}

// ---------------------------------------------------------------------------
// Region expansion + read extraction
// ---------------------------------------------------------------------------

final _privateIdent = RegExp(r'\b(_[A-Za-z0-9_]+)\b');

/// Expands [seeds] through the private members they name, [depth] levels deep.
///
/// Depth 2 is what direction A needs and no more: dispatch entry (0) ->
/// `_stdListGenerate` (1) -> `_extractBinaryArgs` / `_lazyFields` (2). Every
/// level past that reaches general-purpose evaluators whose own map reads have
/// nothing to do with the function's input descriptor.
String expandRegion(
  Iterable<String> seeds,
  Map<String, String> members,
  int depth,
) {
  final texts = <String>[...seeds];
  final seen = <String>{};
  var frontier = <String>{};
  for (final t in texts) {
    frontier.addAll(_privateIdent.allMatches(t).map((m) => m.group(1)!));
  }
  for (var d = 0; d < depth && frontier.isNotEmpty; d++) {
    final next = <String>{};
    for (final name in frontier) {
      if (!seen.add(name)) continue;
      final body = members[name];
      if (body == null) continue;
      texts.add(body);
      next.addAll(_privateIdent.allMatches(body).map((m) => m.group(1)!));
    }
    frontier = next.difference(seen);
  }
  return texts.join('\n');
}

/// A local bound to an input message map.
final _bindLocal = RegExp(
  r'\b(?:final|var)\s+([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(?:await\s+)?'
  r'(?:_stdAsMap|_asMap|_lazyFields|_extractFields|_messageFields)\b',
);

/// A parameter declared as a String-keyed map — the compiler's
/// `Map<String, Expression> f` and the engine's `Map<String, Object?> input`.
final _bindParam = RegExp(
  r'Map<\s*String\s*,[^>]*>\s+([A-Za-z_][A-Za-z0-9_]*)\s*[,)]',
);

/// An untyped parameter of a handler written as `Object? input`.
final _bindObjectParam = RegExp(r'Object\?\s+([A-Za-z_][A-Za-z0-9_]*)\s*[,)]');

/// The parameter of the closure a dispatch entry IS — `'negate': (i) => …`.
/// Anchored at the start of the entry so the inner closures an entry passes
/// along (`_stdConvert(i, (v) => …)`, whose `v` is an unwrapped VALUE, not the
/// input message) are not mistaken for the input.
final _entryClosureParam = RegExp(
  r'^\s*\(([A-Za-z_][A-Za-z0-9_]*)\)\s*(?:async\s*)?(?:=>|\{)',
);

Set<String> entryClosureParams(Iterable<String> entries) => {
  for (final e in entries)
    if (_entryClosureParam.firstMatch(e) case final m?) m.group(1)!,
};

/// `pair.name == 'element'` / `f.name != 'type_args'` — reading a field off a
/// `MessageCreation` by comparing its name, which is how the lazy `map_create`
/// evaluator and the compiler's `typed_list` lowering select fields.
final _nameCompare = RegExp(
  '''(?:\\.name|\\bname)\\s*[=!]=\\s*['"]([A-Za-z0-9_\$]+)['"]''',
);

/// Every input-message field name [region] reads.
///
/// Two shapes, both keyed off the set of variables that HOLD the input message
/// (locals bound from `_stdAsMap` & friends, `Map<String, …>` / `Object?`
/// parameters, and the dispatch closure's own parameter plus any in
/// [extraVars]):
///
///   * `v['key']` — a direct lookup;
///   * `_anyPrivateHelper(v, 'key', …)` — a helper that takes the input and a
///     field NAME, e.g. `_extractField(i, 'type')`,
///     `_stringFieldValue(f, 'method')`, `_concurrencyHandle(i, 'mutex', …)`.
///     Deriving this from the argument SHAPE rather than from a list of helper
///     names is what keeps the gate honest when a new helper appears.
Set<String> readKeys(String region, {Set<String> extraVars = const {}}) {
  final keys = <String>{};
  for (final m in _nameCompare.allMatches(region)) {
    keys.add(m.group(1)!);
  }
  final vars = <String>{
    ...extraVars,
    ..._bindLocal.allMatches(region).map((m) => m.group(1)!),
    ..._bindParam.allMatches(region).map((m) => m.group(1)!),
    ..._bindObjectParam.allMatches(region).map((m) => m.group(1)!),
  };
  for (final v in vars) {
    final escaped = RegExp.escape(v);
    final index = RegExp(
      '''\\b$escaped\\??\\[\\s*['"]([A-Za-z0-9_\$]+)['"]\\s*\\]''',
    );
    for (final m in index.allMatches(region)) {
      keys.add(m.group(1)!);
    }
    final helper = RegExp(
      '''_[A-Za-z0-9_]+\\(\\s*$escaped\\s*,\\s*['"]([A-Za-z0-9_\$]+)['"]''',
    );
    for (final m in helper.allMatches(region)) {
      keys.add(m.group(1)!);
    }
  }
  return keys;
}

/// A dispatch entry that is a bare method reference — `'print': _stdPrint,`.
final _tearOffEntry = RegExp(r'^(_[A-Za-z0-9_]+),?$');

/// The body of the EAGER handler a dispatch entry names, and nothing else.
///
/// Direction B's scope: an inline-closure entry IS the handler, so its own text
/// is the whole region; a tear-off entry names one method, so that method's
/// body is. Neither is expanded further — one step past the handler reaches
/// general-purpose helpers (`_ballToStringAsync` binds `_stdAsMap` on an error
/// OBJECT and reads `m['message']` off it), whose map reads say nothing about
/// this function's input descriptor and would be reported as phantom findings.
String eagerHandlerRegion(String entry, Map<String, String> members) {
  final trimmed = entry.trim();
  final tearOff = _tearOffEntry.firstMatch(trimmed);
  if (tearOff != null) return members[tearOff.group(1)!] ?? trimmed;
  return trimmed;
}

// ---------------------------------------------------------------------------
// Declarations
// ---------------------------------------------------------------------------

/// The eight universal std modules, each paired with the builder that DECLARES
/// its types and base functions — the same set
/// `std_reverse_closed_set_test.dart` pins.
const _stdBuilders = <String, Module Function()>{
  'std': buildStdModule,
  'std_collections': buildStdCollectionsModule,
  'std_io': buildStdIoModule,
  'std_memory': buildStdMemoryModule,
  'std_convert': buildStdConvertModule,
  'std_fs': buildStdFsModule,
  'std_time': buildStdTimeModule,
  'std_concurrency': buildStdConcurrencyModule,
};

/// One declared base function: which module declared it, which input type it
/// names, and its description (which is where alternative field spellings are
/// documented).
class DeclaredFunction {
  DeclaredFunction(this.module, this.name, this.inputType, this.description);

  final String module;
  final String name;
  final String inputType;
  final String description;

  String get qualified => '$module.$name';
}

/// `module.TypeName` -> declared field names, for every std type definition.
Map<String, List<String>> declaredTypeFields() {
  final out = <String, List<String>>{};
  _stdBuilders.forEach((module, build) {
    for (final t in build().typeDefs) {
      out['$module.${t.name}'] = [for (final f in t.descriptor.field) f.name];
    }
  });
  return out;
}

/// Every base function the eight builders declare.
List<DeclaredFunction> declaredFunctions() {
  final out = <DeclaredFunction>[];
  _stdBuilders.forEach((module, build) {
    for (final f in build().functions) {
      if (!f.isBase) continue;
      out.add(DeclaredFunction(module, f.name, f.inputType, f.description));
    }
  });
  return out;
}

/// Field names declared by ANY type of [module] — the allowance direction B
/// gives a handler that reads a NESTED message of its own module (the `switch`
/// handler walking `SwitchCase.is_default`, `map_create` walking
/// `MapCreateEntry.key`).
Map<String, Set<String>> moduleFieldNames(
  Map<String, List<String>> typeFields,
) {
  final out = <String, Set<String>>{};
  typeFields.forEach((key, fields) {
    final module = key.substring(0, key.indexOf('.'));
    out.putIfAbsent(module, () => <String>{}).addAll(fields);
  });
  return out;
}

/// Identifiers a function description names in backticks — the repo's existing
/// convention for documenting an alternative spelling a handler also accepts
/// ("Engines also accept `count` for `length`").
final _backticked = RegExp(r'`([A-Za-z0-9_$]+)`');

Set<String> documentedAliases(String description) =>
    _backticked.allMatches(description).map((m) => m.group(1)!).toSet();

/// Keys that belong to the universal CALL convention rather than to any one
/// function's input descriptor, so no descriptor declares them:
///
///   * `self` — the receiver of a method-shaped call;
///   * `arg0`, `arg1`, … — positional arguments (matched separately);
///   * `__…__` — engine-internal runtime markers (`__type__`, `__super__`,
///     `__ball_set__`), which are values the runtime stores in its own maps,
///     never Ball IR fields.
const _callConventionKeys = <String>{'self'};

final _positionalArg = RegExp(r'^arg\d+$');

bool _isConventionKey(String key) =>
    _callConventionKeys.contains(key) ||
    _positionalArg.hasMatch(key) ||
    key.startsWith('__') ||
    // A Dart string literal carrying an interpolation (`'arg$i'`) or a record's
    // positional component (`$1`) is not a fixed field name.
    key.contains(r'$');

// ---------------------------------------------------------------------------
// The two checks, as pure functions (so the negative controls can drive them)
// ---------------------------------------------------------------------------

/// Direction A: declared field names no handler reads.
///
/// Keyed by `module.TypeName`; the read set is the UNION over every function
/// declaring that type, because a shared input type (`BinaryInput`,
/// `NumFormatInput`) is a union of the shapes its family uses.
Map<String, List<String>> declaredNeverRead({
  required Map<String, List<String>> typeFields,
  required Map<String, Set<String>> readsByType,
}) {
  final out = <String, List<String>>{};
  typeFields.forEach((typeKey, fields) {
    if (fields.isEmpty) return;
    final reads = readsByType[typeKey];
    if (reads == null) return; // not reachable from any dispatch entry
    final missing = [
      for (final f in fields)
        if (!reads.contains(f)) f,
    ];
    if (missing.isNotEmpty) out[typeKey] = missing;
  });
  return out;
}

/// Direction B: keys a handler reads that nothing declares or documents.
Map<String, List<String>> readNeverDeclared({
  required List<DeclaredFunction> functions,
  required Map<String, List<String>> typeFields,
  required Map<String, Set<String>> moduleFields,
  required Map<String, Set<String>> readsByFunction,
}) {
  final out = <String, List<String>>{};
  for (final fn in functions) {
    final reads = readsByFunction[fn.qualified];
    if (reads == null || reads.isEmpty) continue;
    final declared = typeFields['${fn.module}.${fn.inputType}'];
    if (declared == null) continue;
    final allowed = <String>{
      ...declared,
      ...?moduleFields[fn.module],
      ...documentedAliases(fn.description),
    };
    final extra = [
      for (final k in reads)
        if (!allowed.contains(k) && !_isConventionKey(k)) k,
    ]..sort();
    if (extra.isNotEmpty) out[fn.qualified] = extra;
  }
  return out;
}

// ---------------------------------------------------------------------------

const _howToFixA =
    'FIX: spell the declared field the way the handler reads it (open '
    'dart/engine/lib/engine_std.dart or dart/compiler/lib/compiler.dart and '
    'read the handler), or make the handler read the declared name — then\n'
    '  cd dart/shared  && dart run bin/gen_std.dart\n'
    '  cd dart/encoder && dart run bin/gen_std_coverage.dart\n'
    'A field nothing reads is a contract every OTHER target implements against '
    'and the reference implementation ignores (issue #771).';

const _howToFixB =
    'FIX: either declare the field on the input TypeDefinition in the matching '
    'dart/shared/lib/std*.dart builder, or — when it is an alternative '
    'spelling the handler merely tolerates — name it in BACKTICKS in that '
    "function's description, which is the convention std.dart already states "
    '("alternative spellings each handler also accepts are named in the '
    'FUNCTION description rather than declared as extra fields"). Then\n'
    '  cd dart/shared  && dart run bin/gen_std.dart\n'
    '  cd dart/encoder && dart run bin/gen_std_coverage.dart\n'
    'A key only the Dart engine knows about is a shape no other target can '
    'discover from std.json (issue #771).';

void main() {
  final root = _repoRoot();

  late final Map<String, String> engineSources;
  late final Map<String, String> compilerSources;
  late final Map<String, String> members;
  late final Map<String, List<String>> entryRegions;
  late final Map<String, String> eagerEntries;

  late final List<DeclaredFunction> functions;
  late final Map<String, List<String>> typeFields;
  late final Map<String, Set<String>> moduleFields;
  late final Map<String, Set<String>> readsByType;
  late final Map<String, Set<String>> readsByFunction;

  setUpAll(() {
    String load(String rel) =>
        stripDartComments(File('${root.path}/$rel').readAsStringSync());

    engineSources = {for (final s in _engineSources) s: load(s)};
    compilerSources = {for (final s in _compilerSources) s: load(s)};
    members = indexMembers([
      ...engineSources.values,
      ...compilerSources.values,
    ]);
    entryRegions = allEntryRegions(
      engineSources: engineSources,
      compilerSources: compilerSources,
    );
    eagerEntries = eagerDispatchEntries(engineSources[_engineSources.first]!);

    functions = declaredFunctions();
    typeFields = declaredTypeFields();
    moduleFields = moduleFieldNames(typeFields);

    // Direction A: engine + compiler, depth 2, unioned per declared input type.
    readsByType = <String, Set<String>>{};
    for (final fn in functions) {
      final seeds = entryRegions[fn.name];
      if (seeds == null) continue;
      final typeKey = '${fn.module}.${fn.inputType}';
      if (!typeFields.containsKey(typeKey)) continue;
      readsByType
          .putIfAbsent(typeKey, () => <String>{})
          .addAll(
            readKeys(
              expandRegion(seeds, members, 2),
              extraVars: entryClosureParams(seeds),
            ),
          );
    }

    // Direction B: the engine's EAGER dispatch handler only, depth 1 (the
    // handler's own body). See the header for why its scope is narrower.
    readsByFunction = <String, Set<String>>{};
    for (final fn in functions) {
      final entry = eagerEntries[fn.name];
      if (entry == null) continue;
      readsByFunction[fn.qualified] = readKeys(
        eagerHandlerRegion(entry, members),
        extraVars: entryClosureParams([entry]),
      );
    }
  });

  group('field signature gate 0 — the derivations are non-vacuous (#771)', () {
    test('comment stripping keeps code and drops prose', () {
      const sample = '''
  // Labels (handled lazily in _evalCall)
  'labeled': (_) => null,
  /* block 'entries' */
  final s = 'keep // this';
''';
      final stripped = stripDartComments(sample);
      expect(stripped, contains("'labeled'"));
      expect(stripped, contains("'keep // this'"));
      expect(stripped, isNot(contains('_evalCall')));
      expect(stripped, isNot(contains("block 'entries'")));
    });

    test('the member index is non-vacuous', () {
      expect(
        members.length,
        greaterThan(200),
        reason:
            'indexed only ${members.length} private members from the engine '
            'and compiler sources — the declaration regex has stopped '
            'matching; fix it before trusting anything below',
      );
      for (final anchor in [
        '_stdListGenerate',
        '_extractUnaryArg',
        '_extractBinaryArgs',
        '_lazyFields',
        '_compileTearOff',
      ]) {
        expect(
          members.keys,
          contains(anchor),
          reason: 'the member index missed the well-known $anchor',
        );
      }
    });

    test('the eager dispatch extraction is non-vacuous', () {
      expect(
        eagerEntries.length,
        greaterThan(250),
        reason:
            'extracted only ${eagerEntries.length} dispatch keys from '
            '_buildStdDispatch() — it has always had 250+',
      );
      for (final anchor in ['print', 'add', 'list_generate', 'math_lcm']) {
        expect(eagerEntries.keys, contains(anchor));
      }
    });

    test('the declaration derivation is non-vacuous', () {
      expect(
        functions.length,
        greaterThan(250),
        reason:
            'the std builders declare 270+ base functions; got '
            '${functions.length}',
      );
      expect(
        typeFields.length,
        greaterThan(60),
        reason:
            'the std builders declare 60+ input types; got '
            '${typeFields.length}',
      );
      for (final module in _stdBuilders.keys) {
        expect(
          functions.any((f) => f.module == module),
          isTrue,
          reason: '$module contributed no base function',
        );
      }
      expect(typeFields['std.ListGenerateInput'], ['length', 'generator']);
      expect(typeFields['std.BinaryInput'], ['left', 'right']);
    });

    test('the read extraction is non-vacuous', () {
      final typesWithReads = readsByType.entries
          .where((e) => e.value.isNotEmpty)
          .length;
      expect(
        typesWithReads,
        greaterThan(30),
        reason:
            'extracted reads for only $typesWithReads declared input types; '
            'the read patterns have stopped matching',
      );
      final fnsWithReads = readsByFunction.entries
          .where((e) => e.value.isNotEmpty)
          .length;
      expect(
        fnsWithReads,
        greaterThan(50),
        reason:
            'extracted eager-handler reads for only $fnsWithReads functions',
      );
      // Anchors from three different read shapes.
      expect(readsByType['std.ListGenerateInput'], contains('length'));
      expect(readsByType['std.BinaryInput'], contains('left'));
      expect(readsByType['std.TearOffInput'], contains('method'));
      expect(readsByType['std.MapCreateInput'], contains('element'));
    });
  });

  group('field signature A — every declared input field is read (#771)', () {
    test('no std input type declares a field no handler reads', () {
      final offenders = declaredNeverRead(
        typeFields: typeFields,
        readsByType: readsByType,
      );
      final lines =
          (offenders.entries.toList()..sort((a, b) => a.key.compareTo(b.key)))
              .map((e) => '${e.key}: ${e.value.join(', ')}')
              .toList();
      expect(
        lines,
        isEmpty,
        reason:
            'DECLARED but NEVER READ (${lines.length} types):\n'
            '  ${lines.join('\n  ')}\n'
            'Each of these names a field in dart/shared/std.json that neither '
            'the Dart reference engine nor the Dart compiler ever looks up. '
            'Every other target implements against that descriptor.\n'
            '$_howToFixA',
      );
    });

    test('NEGATIVE CONTROL: a renamed field is reported', () {
      // The #771 example, verbatim: ListGenerateInput declaring `len` while
      // _stdListGenerate reads length/count/arg0.
      final mutated = Map<String, List<String>>.from(typeFields);
      mutated['std.ListGenerateInput'] = ['len', 'generator'];
      final offenders = declaredNeverRead(
        typeFields: mutated,
        readsByType: readsByType,
      );
      expect(
        offenders['std.ListGenerateInput'],
        ['len'],
        reason:
            'the direction-A check did not fire on the exact drift issue #771 '
            'describes — it is not load-bearing',
      );
    });
  });

  group('field signature B — every read key is declared or documented '
      '(#771)', () {
    test('no eager std handler reads a key nothing declares or documents', () {
      final offenders = readNeverDeclared(
        functions: functions,
        typeFields: typeFields,
        moduleFields: moduleFields,
        readsByFunction: readsByFunction,
      );
      final lines =
          (offenders.entries.toList()..sort((a, b) => a.key.compareTo(b.key)))
              .map((e) => '${e.key}: ${e.value.join(', ')}')
              .toList();
      expect(
        lines,
        isEmpty,
        reason:
            'READ but NEITHER DECLARED NOR DOCUMENTED (${lines.length} '
            'functions):\n'
            '  ${lines.join('\n  ')}\n'
            'The Dart engine accepts these spellings; nothing in std.json says '
            'so, so no other target can implement them and no encoder knows '
            'they are safe to emit.\n'
            '$_howToFixB',
      );
    });

    test('NEGATIVE CONTROL: an undeclared read key is reported', () {
      final fn = DeclaredFunction(
        'std',
        'list_generate',
        'ListGenerateInput',
        'List built by index: List.generate(length, generator).',
      );
      final offenders = readNeverDeclared(
        functions: [fn],
        typeFields: {
          'std.ListGenerateInput': ['length', 'generator'],
        },
        moduleFields: {
          'std': {'length', 'generator'},
        },
        readsByFunction: {
          'std.list_generate': {'length', 'generator', 'callback', 'arg0'},
        },
      );
      expect(
        offenders['std.list_generate'],
        ['callback'],
        reason:
            'the direction-B check did not fire on an undocumented alias read '
            '— it is not load-bearing',
      );
    });

    test('NEGATIVE CONTROL: documenting the alias clears it', () {
      final fn = DeclaredFunction(
        'std',
        'list_generate',
        'ListGenerateInput',
        'List built by index. Engines also accept `callback` for `generator`.',
      );
      final offenders = readNeverDeclared(
        functions: [fn],
        typeFields: {
          'std.ListGenerateInput': ['length', 'generator'],
        },
        moduleFields: {
          'std': {'length', 'generator'},
        },
        readsByFunction: {
          'std.list_generate': {'length', 'generator', 'callback', 'arg0'},
        },
      );
      expect(offenders, isEmpty);
    });
  });
}
