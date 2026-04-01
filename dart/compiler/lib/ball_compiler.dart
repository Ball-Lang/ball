/// Ball Dart language support library.
///
/// Provides:
/// - [DartCompiler] — translates ball programs into Dart source code (compiler)
/// - [DartEncoder] — translates Dart source code into ball programs (encoder)
/// - [BallEngine] — executes ball programs at runtime (engine)
/// - [PackageEncoder] — encodes a full Dart package directory to a ball [Program]
/// - [PackageCompiler] — compiles a multi-module ball [Program] to a Dart package
/// - [PackageManifest] / [PackageDependency] — structured pubspec.yaml data
/// - [PubspecParser] — parse/generate pubspec.yaml
///
/// Protobuf types and the universal std module come from `package:ball_base`.
library;

export 'package:ball_base/ball_base.dart';
export 'compiler.dart';
export 'package:ball_encoder/encoder.dart';
export 'package:ball_encoder/package_encoder.dart';
export 'package:ball_engine/dart_std.dart' show buildDartStdModule;
export 'package:ball_engine/engine.dart'
    show
        BallEngine,
        BallRuntimeError,
        BallModuleHandler,
        StdModuleHandler,
        BallCallable,
        BallValue;
export 'package_compiler.dart';
