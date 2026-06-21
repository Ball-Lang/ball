/// Ball CLI — inspect, validate, compile, encode, and run ball programs.
///
/// Thin entry-point shim. All command logic lives in
/// `package:ball_cli/src/runner.dart` (see [runBall]) so it can be tested
/// in-process. This file only wires `args` through and turns the returned exit
/// code into a real process exit.
///
/// Usage:
///   ball info     `<input.ball.json>`   — inspect ball program structure
///   ball validate `<input.ball.json>`   — check ball program validity
///   ball compile  `<input.ball.json>`   — compile ball program to Dart source
///   ball encode   `<input.dart>`        — encode Dart source to ball program
///   ball run      `<input.ball.json>`   — execute ball program
///   ball round-trip `<input.dart>`      — encode → compile → show diff
///   ball version                        — print version
library;

import 'dart:io';

import 'package:ball_cli/src/runner.dart';

Future<void> main(List<String> args) async => exit(await runBall(args));
