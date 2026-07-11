/// Cross-language standard library for the ball programming language.
///
/// Provides:
/// - Buf-generated protobuf types ([Program], [Module], [Expression], etc.)
/// - `buildStd*Module` builders for the standard-library modules: [buildStdModule]
///   (`std`), [buildStdCollectionsModule], [buildStdIoModule], [buildStdMemoryModule],
///   [buildStdConcurrencyModule], [buildStdConvertModule], [buildStdFsModule],
///   [buildStdTimeModule]
/// - The Editions-capable protobuf runtime (re-exported from `ball_protobuf`),
///   the [BallFile] model, and the capability/termination analyzers
///
/// Every target-language compiler (Dart, Go, Python, …) depends on this
/// package for the shared protobuf types and the universal std definition.
library;

export 'gen/ball/v1/ball.pb.dart';
export 'gen/ball/v1/ball.pbenum.dart';
export 'gen/google/protobuf/descriptor.pb.dart';
export 'gen/google/protobuf/descriptor.pbenum.dart';
export 'std.dart' show buildStdModule;
export 'std_collections.dart' show buildStdCollectionsModule;
export 'std_io.dart' show buildStdIoModule;
export 'std_memory.dart' show buildStdMemoryModule;
export 'std_concurrency.dart' show buildStdConcurrencyModule;
export 'std_convert.dart' show buildStdConvertModule;
export 'std_fs.dart' show buildStdFsModule;
export 'std_time.dart' show buildStdTimeModule;
export 'ball_proto.dart' show buildBallProtoModule;
// The capability + termination analyzers are `part of 'cli_core.dart'` (they
// self-host through the Ball engine, so they follow cli_core's engine-safe
// authoring rules). Import `package:ball_base/cli_core.dart` for their Map-based
// API (`analyzeCapabilities`, `formatCapabilityReport`, `checkPolicy`,
// `analyzeTermination`, `formatTerminationReport`, `auditReport`, …).
export 'cli_core.dart'
    show
        analyzeCapabilities,
        analyzeModuleCapabilities,
        analyzeCapabilitiesReachable,
        formatCapabilityReport,
        checkPolicy,
        checkPolicyViolations,
        analyzeTermination,
        analyzeModuleTermination,
        formatTerminationReport,
        terminationHasErrors,
        buildCapabilityTable,
        capabilityNames,
        capabilityRisk,
        lookupCapability,
        auditReport;
// The protobuf engine now lives in its own publishable package; re-export it so
// existing `package:ball_base/ball_base.dart` consumers keep the same surface.
export 'package:ball_protobuf/ball_protobuf.dart';
export 'ball_file.dart'
    show
        BallFile,
        BallProgramFile,
        BallModuleFile,
        BallFileFormatException,
        programTypeUrl,
        moduleTypeUrl,
        decodeBallFileBinary,
        decodeBallFileJson,
        decodeProgramJson,
        decodeModuleJson,
        decodeProgramBinary,
        decodeModuleBinary,
        encodeBallFileBinary,
        encodeBallFileJson;
