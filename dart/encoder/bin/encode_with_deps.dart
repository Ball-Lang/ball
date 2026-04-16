/// Demonstrates PackageEncoder's external dependency resolution.
///
/// Downloads a pub package, encodes it twice (with and without
/// resolveExternalDeps), and compares the results to show how stub
/// modules get replaced by fully-resolved dependency modules.
///
///   dart run ball_encoder:encode_with_deps <package-name> [--version <ver>] [--max-depth <n>]
library;

import 'dart:io';

import 'package:ball_base/gen/ball/v1/ball.pb.dart';
import 'package:ball_encoder/package_encoder.dart';
import 'package:ball_encoder/pub_client.dart';

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln(
      'Usage: encode_with_deps <package-name> '
      '[--version <ver>] [--max-depth <n>]',
    );
    exit(1);
  }

  final name = args.first;
  final verIdx = args.indexOf('--version');
  final constraint =
      verIdx >= 0 && verIdx + 1 < args.length ? args[verIdx + 1] : 'any';
  final depthIdx = args.indexOf('--max-depth');
  final maxDepth =
      depthIdx >= 0 && depthIdx + 1 < args.length
          ? int.tryParse(args[depthIdx + 1]) ?? 10
          : 10;

  final client = PubClient();

  try {
    // ── Step 1: Download the package ──────────────────────────────────────
    stdout.writeln('=== Encode with External Dependency Resolution ===');
    stdout.writeln('');
    stdout.writeln('1. Resolving $name@$constraint from pub.dev...');
    final versionInfo = await client.resolveVersion(name, constraint);
    stdout.writeln('   Resolved: v${versionInfo.version}');

    stdout.writeln('2. Downloading package archive...');
    final pkgDir = await client.downloadPackage(
      name,
      versionInfo.version,
      archiveUrl: versionInfo.archiveUrl,
    );
    stdout.writeln('   Extracted to: ${pkgDir.path}');

    // ── Step 2: Encode WITHOUT dependency resolution (stubs only) ────────
    stdout.writeln('');
    stdout.writeln('3. Encoding WITHOUT resolveExternalDeps (stubs only)...');
    final swStubs = Stopwatch()..start();
    final stubEncoder = PackageEncoder(pkgDir);
    final stubProgram = stubEncoder.encode();
    swStubs.stop();

    final stubModules = stubProgram.modules;
    var stubFnCount = 0;
    final stubModuleNames = <String>[];
    final userModuleNames = <String>[];
    final baseModuleNames = <String>[];

    for (final m in stubModules) {
      stubFnCount += m.functions.length;
      if (m.functions.isEmpty && m.name != '__assets__') {
        stubModuleNames.add(m.name);
      } else if (m.functions.every((f) => f.isBase) && m.functions.isNotEmpty) {
        baseModuleNames.add(m.name);
      } else {
        userModuleNames.add(m.name);
      }
    }

    stdout.writeln('   Time: ${swStubs.elapsedMilliseconds}ms');
    stdout.writeln('   Total modules: ${stubModules.length}');
    stdout.writeln('   Total functions: $stubFnCount');
    stdout.writeln('   User modules (with code): ${userModuleNames.length}');
    stdout.writeln(
      '   Base modules (std/dart_std): ${baseModuleNames.length}',
    );
    stdout.writeln(
      '   Stub modules (empty, external deps): ${stubModuleNames.length}',
    );
    if (stubModuleNames.isNotEmpty) {
      stdout.writeln('   Stub module names:');
      for (final s in stubModuleNames) {
        stdout.writeln('     - $s');
      }
    }

    // ── Step 3: Encode WITH dependency resolution ────────────────────────
    stdout.writeln('');
    stdout.writeln(
      '4. Encoding WITH resolveExternalDeps '
      '(maxDepth=$maxDepth)...',
    );
    final swResolved = Stopwatch()..start();

    // Create a fresh PubClient for the resolver (the PackageEncoder may
    // use it for multiple sequential downloads).
    final resolverClient = PubClient();
    final resolvedEncoder = PackageEncoder(
      pkgDir,
      resolveExternalDeps: true,
      pubClient: resolverClient,
      maxDepth: maxDepth,
    );

    // encodeAsync() calls encode() first, then resolves stubs.
    late final Program resolvedProgram;
    String? asyncError;
    try {
      resolvedProgram = await resolvedEncoder.encodeAsync();
    } catch (e, st) {
      asyncError = '$e\n$st';
    }
    swResolved.stop();

    if (asyncError != null) {
      stdout.writeln('   ERROR during encodeAsync():');
      stdout.writeln('   $asyncError');
      stdout.writeln('');
      stdout.writeln('=== Analysis ===');
      stdout.writeln(
        'The encodeAsync() method failed. This suggests the async '
        'dependency resolution path has issues that need fixing in '
        'package_encoder.dart.',
      );
      resolverClient.close();
      await _cleanup(pkgDir);
      client.close();
      return;
    }

    final resolvedModules = resolvedProgram.modules;
    var resolvedFnCount = 0;
    final resolvedStubNames = <String>[];
    final resolvedUserNames = <String>[];
    final resolvedBaseNames = <String>[];
    final resolvedDepNames = <String>[];

    for (final m in resolvedModules) {
      resolvedFnCount += m.functions.length;
      if (m.functions.isEmpty && m.name != '__assets__') {
        resolvedStubNames.add(m.name);
      } else if (m.functions.every((f) => f.isBase) &&
          m.functions.isNotEmpty) {
        resolvedBaseNames.add(m.name);
      } else {
        // Distinguish original user modules from newly-resolved dep modules.
        if (userModuleNames.contains(m.name)) {
          resolvedUserNames.add(m.name);
        } else if (!baseModuleNames.contains(m.name)) {
          resolvedDepNames.add(m.name);
        }
      }
    }

    stdout.writeln('   Time: ${swResolved.elapsedMilliseconds}ms');
    stdout.writeln('   Total modules: ${resolvedModules.length}');
    stdout.writeln('   Total functions: $resolvedFnCount');
    stdout.writeln('   User modules (original): ${resolvedUserNames.length}');
    stdout.writeln('   Base modules: ${resolvedBaseNames.length}');
    stdout.writeln(
      '   Resolved dep modules (new): ${resolvedDepNames.length}',
    );
    stdout.writeln(
      '   Remaining stubs (unresolved): ${resolvedStubNames.length}',
    );

    if (resolvedDepNames.isNotEmpty) {
      stdout.writeln('   Resolved dependency modules:');
      for (final d in resolvedDepNames.take(30)) {
        final fnCount =
            resolvedModules.firstWhere((m) => m.name == d).functions.length;
        stdout.writeln('     + $d ($fnCount functions)');
      }
      if (resolvedDepNames.length > 30) {
        stdout.writeln(
          '     ... and ${resolvedDepNames.length - 30} more',
        );
      }
    }

    if (resolvedStubNames.isNotEmpty) {
      stdout.writeln('   Remaining stub modules:');
      for (final s in resolvedStubNames) {
        stdout.writeln('     - $s (still empty)');
      }
    }

    // ── Step 4: Comparison summary ────────────────────────────────────────
    stdout.writeln('');
    stdout.writeln('=== Comparison Summary ===');
    stdout.writeln(
      '  Modules:   ${stubModules.length} (stubs) -> '
      '${resolvedModules.length} (resolved)  '
      '[${_delta(resolvedModules.length - stubModules.length)}]',
    );
    stdout.writeln(
      '  Functions: $stubFnCount (stubs) -> '
      '$resolvedFnCount (resolved)  '
      '[${_delta(resolvedFnCount - stubFnCount)}]',
    );
    stdout.writeln(
      '  Stubs:     ${stubModuleNames.length} -> '
      '${resolvedStubNames.length}  '
      '[${_delta(resolvedStubNames.length - stubModuleNames.length)}]',
    );

    final int stubsResolved = stubModuleNames.length - resolvedStubNames.length;
    if (stubsResolved > 0) {
      stdout.writeln(
        '  External deps successfully resolved: $stubsResolved',
      );
    } else if (stubsResolved == 0 && stubModuleNames.isNotEmpty) {
      stdout.writeln('');
      stdout.writeln('  WARNING: No stubs were resolved despite '
          '${stubModuleNames.length} stub(s) present.');
      stdout.writeln('  This may indicate an issue with the async '
          'dependency resolution path.');
      stdout.writeln('');
      stdout.writeln('  Possible causes:');
      stdout.writeln(
        '  - _moduleNameToPackageName() may not map stub names to '
        'pub package names correctly',
      );
      stdout.writeln(
        '  - The stub module names (generated by DartEncoder) may not '
        'match what _resolveExternalDeps expects',
      );
      stdout.writeln(
        '  - Downloaded packages may fail to parse (missing pubspec.yaml '
        'in temp dir, analysis errors, etc.)',
      );
      stdout.writeln(
        '  - Errors in recursive encoding are silently caught '
        '(see the catch block in _resolveExternalDeps)',
      );
    }

    resolverClient.close();
    await _cleanup(pkgDir);
  } catch (e, st) {
    stderr.writeln('Fatal error: $e');
    stderr.writeln(st);
    exit(2);
  } finally {
    client.close();
  }

  stdout.writeln('');
  stdout.writeln('Done.');
}

String _delta(int n) => n >= 0 ? '+$n' : '$n';

Future<void> _cleanup(Directory dir) async {
  try {
    await dir.delete(recursive: true);
  } catch (_) {}
}
