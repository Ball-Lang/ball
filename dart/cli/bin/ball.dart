/// Ball CLI — inspect, validate, compile, encode, and run ball programs.
///
/// Thin entry-point shim. All command logic lives in
/// `package:ball_cli/src/runner.dart` (see [runBall]) so it can be tested
/// in-process. This file only wires `args` through and turns the returned exit
/// code into a real process exit.
///
/// Commands: `info`, `validate`, `compile`, `encode`, `run`, `round-trip`,
/// `audit`, `build`, `init`, `add`, `resolve`, `tree`, `publish`, `version`.
/// Run `ball help` for the authoritative, up-to-date command list and usage
/// (see `_printUsage` in `runner.dart`).
library;

import 'dart:io';

import 'package:ball_cli/src/runner.dart';

Future<void> main(List<String> args) async => exit(await runBall(args));
