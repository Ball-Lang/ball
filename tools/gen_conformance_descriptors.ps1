#!/usr/bin/env pwsh
# Regenerate the upstream-conformance FileDescriptorSet that the ball_protobuf
# descriptor bridge consumes (tests/editions/descriptors/test_messages.fds.binpb).
# Covers all three conformance message families: proto2, proto3, and edition2023.
#
# The test-message .proto files ship with the protobuf source, which CMake
# fetches under cpp/<build>/_deps/protobuf-src. We locate that checkout and run
# protoc (--include_imports for a self-contained set). Pin: protoc 28.2 supports
# edition 2023; do NOT regenerate against an older protoc.
#
# Usage: tools/gen_conformance_descriptors.ps1 [-Check]
param([switch]$Check)
$ErrorActionPreference = 'Stop'
$root = Resolve-Path (Join-Path $PSScriptRoot '..')
$out = Join-Path $root 'tests/editions/descriptors/test_messages.fds.binpb'

$pb = $null
foreach ($d in @('cpp/build3/_deps/protobuf-src', 'cpp/build/_deps/protobuf-src',
                 'cpp/ci-build/_deps/protobuf-src', 'cpp/build-conformance/_deps/protobuf-src')) {
    $cand = Join-Path $root $d
    if (Test-Path (Join-Path $cand 'conformance/test_protos/test_messages_edition2023.proto')) { $pb = $cand; break }
}
if (-not $pb) { Write-Error 'protobuf source not found; configure a cpp build first (it FetchContent''s protobuf).'; exit 1 }
Write-Host "protoc:   $((Get-Command protoc).Source)"
protoc --version
Write-Host "protobuf: $pb"

$gen = if ($Check) { [System.IO.Path]::GetTempFileName() } else { $out }
New-Item -ItemType Directory -Force (Split-Path $out) | Out-Null
protoc --include_imports `
  -I (Join-Path $pb 'src') -I (Join-Path $pb 'conformance/test_protos') `
  --descriptor_set_out=$gen `
  test_messages_edition2023.proto `
  google/protobuf/test_messages_proto2.proto `
  google/protobuf/test_messages_proto3.proto

if ($Check) {
    if ((Get-FileHash $gen).Hash -eq (Get-FileHash $out).Hash) {
        Write-Host 'OK: descriptor set is up to date.'; Remove-Item $gen
    } else {
        Write-Host '::error::test_messages.fds.binpb is stale — run tools/gen_conformance_descriptors.ps1'
        Remove-Item $gen; exit 1
    }
} else {
    Write-Host "wrote $out"
}
