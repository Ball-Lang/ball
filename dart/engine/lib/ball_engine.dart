/// Ball engine -- interprets and executes Ball programs at runtime.
///
/// Provides:
/// - [BallEngine] -- tree-walking interpreter for Ball programs
/// - [StdModuleHandler] -- dispatches std/dart_std base functions
/// - [BallModuleHandler] -- abstract class for custom module handlers
/// - [buildDartStdModule] -- builds the dart_std module definition
library;

export 'dart_std.dart' show buildDartStdModule;
export 'engine.dart';
