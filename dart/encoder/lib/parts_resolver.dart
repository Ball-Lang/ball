/// Resolve a multi-file Dart library (one main file + `part` files) into a
/// single source string suitable for [DartEncoder.encode].
///
/// `extension X on Class` blocks where `Class` is declared in the main file
/// are merged into that class body so the encoded output dispatches the
/// extension methods as regular class members. Other top-level declarations
/// from part files are appended after the main source.
///
/// Uses the analyzer AST (offsets only — no regex on Dart source).
library;

import 'dart:io';

import 'package:analyzer/dart/analysis/features.dart';
import 'package:analyzer/dart/analysis/utilities.dart' show parseString;
import 'package:analyzer/dart/ast/ast.dart' as ast;

/// Resolve the library rooted at [mainPath] (with `part` directives) into a
/// single concatenated source string with extension methods merged into
/// their target class bodies.
String resolveDartLibrary(String mainPath) {
  final mainFile = File(mainPath);
  final mainDir = mainFile.parent.path.replaceAll('\\', '/');
  final mainSource = mainFile.readAsStringSync();
  return resolveDartLibraryFromSource(
    mainSource,
    partLoader: (uri) => File('$mainDir/$uri').readAsStringSync(),
  );
}

/// Like [resolveDartLibrary] but takes an in-memory [mainSource] plus a
/// [partLoader] that resolves each `part 'X.dart';` URI to source code.
String resolveDartLibraryFromSource(
  String mainSource, {
  required String Function(String uri) partLoader,
}) {
  final mainUnit = _parse(mainSource);

  // Collect part URIs in declaration order.
  final partUris = <String>[];
  for (final directive in mainUnit.directives) {
    if (directive is ast.PartDirective) {
      final uri = directive.uri.stringValue;
      if (uri != null) partUris.add(uri);
    }
  }

  if (partUris.isEmpty) return mainSource;

  // Index classes declared in the main file so we know which extension
  // targets to merge into. Also record the offset of each class's closing
  // `}` so we can splice extension members in front of it.
  final mainClassNames = <String>{};
  final classCloseOffsets = <String, int>{};
  for (final decl in mainUnit.declarations) {
    String? name;
    int? closeOffset;
    if (decl is ast.ClassDeclaration) {
      name = decl.namePart.typeName.lexeme;
      // endToken is the closing `}` token of the class body.
      closeOffset = decl.endToken.offset;
    } else if (decl is ast.MixinDeclaration) {
      name = decl.name.lexeme;
      closeOffset = decl.endToken.offset;
    }
    if (name != null) {
      mainClassNames.add(name);
      if (closeOffset != null) classCloseOffsets[name] = closeOffset;
    }
  }

  // Buckets keyed by main-file class name; values are concatenated member
  // source strings to splice in before the class's closing brace.
  final injections = <String, StringBuffer>{
    for (final n in mainClassNames) n: StringBuffer(),
  };

  // Top-level declarations from part files that aren't extensions on a
  // main-file class — appended verbatim after the main source.
  final topLevelTail = StringBuffer();

  // Dedupe extension members across part files: when multiple parts
  // define the same helper (e.g. `_asMap` appears in engine_eval.dart,
  // engine_invocation.dart, and engine_std.dart with identical bodies),
  // splicing all copies produces "member function already defined"
  // errors in the target. Track keyed by `targetClass.memberName`.
  final seenMembers = <String>{};
  for (final uri in partUris) {
    final partSource = partLoader(uri);
    final partUnit = _parse(partSource);

    for (final decl in partUnit.declarations) {
      if (decl is ast.ExtensionDeclaration) {
        final targetType = decl.onClause?.extendedType.toSource();
        if (targetType != null && mainClassNames.contains(targetType)) {
          // Splice each member into the target class body, deduping
          // by `class.memberName` so identical helpers from multiple
          // extensions don't collide.
          for (final member in decl.body.members) {
            String? memberName;
            if (member is ast.MethodDeclaration) {
              memberName = member.name.lexeme;
            } else if (member is ast.FieldDeclaration) {
              memberName = member.fields.variables
                  .map((v) => v.name.lexeme)
                  .join(',');
            }
            if (memberName != null) {
              final key = '$targetType.$memberName';
              if (seenMembers.contains(key)) continue;
              seenMembers.add(key);
            }
            final memberSrc =
                partSource.substring(member.offset, member.end);
            final buf = injections[targetType]!;
            buf.writeln();
            buf.writeln('  $memberSrc');
          }
          continue;
        }
        // Extension on something else (or external type): keep as-is.
      }
      // Non-extension top-level declaration → append after main source.
      final src = partSource.substring(decl.offset, decl.end);
      topLevelTail.writeln();
      topLevelTail.writeln(src);
    }
  }

  // Splice injections into the main source. Build the result by walking
  // class-close offsets in increasing order, copying chunks of the original
  // source between them and inserting the injected members.
  final mergedClasses = injections.entries
      .where((e) => e.value.isNotEmpty)
      .map((e) => MapEntry(classCloseOffsets[e.key]!, e.value.toString()))
      .toList()
    ..sort((a, b) => a.key.compareTo(b.key));

  // Strip `part 'X.dart';` directives from the main source. We do this
  // via AST offsets too (no regex).
  final partDirectiveSpans = <(int, int)>[];
  for (final directive in mainUnit.directives) {
    if (directive is ast.PartDirective) {
      partDirectiveSpans.add((directive.offset, directive.end));
    }
  }
  partDirectiveSpans.sort((a, b) => a.$1.compareTo(b.$1));

  final buf = StringBuffer();
  var cursor = 0;
  // Edits to apply, in order: either skip a `part` directive, or splice in
  // injected members before a class's closing brace.
  final edits = <(int, int, String?)>[
    for (final s in partDirectiveSpans) (s.$1, s.$2, null),
    for (final m in mergedClasses) (m.key, m.key, m.value),
  ]..sort((a, b) => a.$1.compareTo(b.$1));

  for (final edit in edits) {
    final (start, endExclusive, replacement) = edit;
    buf.write(mainSource.substring(cursor, start));
    if (replacement != null) buf.write(replacement);
    cursor = endExclusive;
  }
  buf.write(mainSource.substring(cursor));
  buf.write(topLevelTail.toString());

  return buf.toString();
}

ast.CompilationUnit _parse(String source) => parseString(
      content: source,
      throwIfDiagnostics: false,
      featureSet: FeatureSet.latestLanguageVersion(),
    ).unit;
