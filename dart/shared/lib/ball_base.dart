/// Cross-language standard library for the ball programming language.
///
/// Provides:
/// - Buf-generated protobuf types ([Program], [Module], [Expression], etc.)
/// - [buildStdModule] — builds the universal `std` base module
/// - [buildStdCollectionsModule] — builds the `std_collections` module
/// - [buildStdIoModule] — builds the `std_io` module
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
export 'ball_proto.dart' show buildBallProtoModule;
export 'capability_table.dart' show Capability, capabilityRiskLevel, lookupCapability;
export 'capability_analyzer.dart' show analyzeCapabilities, formatCapabilityReport, checkPolicy;
export 'termination_analyzer.dart' show analyzeTermination, TerminationReport, TerminationWarning, formatTerminationReport;
