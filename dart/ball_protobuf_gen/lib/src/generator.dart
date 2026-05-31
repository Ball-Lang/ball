/// Top-level generator: `FileDescriptorSet` bytes -> generated `.pb.dart`
/// source files. This is the entry point the plugin (`bin/protoc_gen_ball.dart`)
/// and the golden regen script call.
///
/// It stitches together the two halves from `docs/PROTOBUF_CODEGEN_PLAN.md` §9:
///   * [GenModelBuilder] (target-independent front end) builds the resolved,
///     Editions-aware [GenModel] from the descriptor bridge + the raw
///     `FileDescriptorProto`s; and
///   * [emitDartFile] (the Dart target template) renders each file.
library;

import 'dart_emitter.dart';
import 'gen_model.dart';

/// One generated output file: its `/`-separated path and Dart source.
class GeneratedDartFile {
  final String path;
  final String content;
  const GeneratedDartFile(this.path, this.content);
}

/// Generates `.pb.dart` source for every file in the `FileDescriptorSet`
/// [fdsBytes] whose name appears in [filesToGenerate].
///
/// An empty [filesToGenerate] generates every file in the set (used by the
/// golden regen script, which wants all of them). The whole set is always
/// indexed so cross-file references resolve.
List<GeneratedDartFile> generateDartModels(
  List<int> fdsBytes, {
  Set<String> filesToGenerate = const {},
}) {
  final builder = GenModelBuilder.fromBytes(fdsBytes);
  final files = builder.buildFiles(filesToGenerate);
  return [
    for (final f in files) GeneratedDartFile(f.outputPath, emitDartFile(f)),
  ];
}

/// Generates ONE self-contained `.pb.dart` for the whole `FileDescriptorSet`
/// [fdsBytes]: every message + enum across every file, in one shared descriptor
/// registry, with no cross-file imports.
///
/// This is what the golden test and its regen script use — a single checked-in
/// file the test imports directly. [outputPath] is stamped into the header.
GeneratedDartFile generateCombinedDartFile(
  List<int> fdsBytes, {
  String outputPath = 'test_messages.pb.dart',
}) {
  final builder = GenModelBuilder.fromBytes(fdsBytes);
  final file = builder.buildCombined(outputPath);
  return GeneratedDartFile(file.outputPath, emitDartFile(file));
}
