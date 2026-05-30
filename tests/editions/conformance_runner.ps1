#!/usr/bin/env pwsh
# Editions conformance runner.
#
# Proves the Ball editions engine resolves and encodes identically across the
# legacy (proto2/proto3) and editions paths, and that the feature-aware binary +
# JSON codecs round-trip. Delegates to the Dart harness in ball_base; prints
# "Results: N passed, M failed, T total" and exits non-zero on any failure (the
# format the conformance CI matrix scrapes). See docs/EDITIONS_SPEC.md.
#
# Note: this is the self-checkable subset of conformance. Full upstream
# conformance against TestAllTypes* is gated on embedding those descriptors and
# is tracked separately (see dart/shared/lib/protobuf/conformance.dart).
$ErrorActionPreference = 'Stop'
$root = Resolve-Path (Join-Path (Join-Path $PSScriptRoot '..') '..')
Push-Location (Join-Path (Join-Path $root 'dart') 'shared')
try {
    dart run tool/editions_conformance.dart
    exit $LASTEXITCODE
} finally {
    Pop-Location
}
