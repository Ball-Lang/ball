#Requires -Version 7
<#
.SYNOPSIS
    Regenerate (or CI-check) the protobuf Editions FeatureSetDefaults golden files.

.DESCRIPTION
    Uses protoc --edition_defaults_out (available in protoc >=27, not shown in
    --help but confirmed empirically with protoc 28.2) to emit a binary
    FeatureSetDefaults message, then decodes it to a human-readable .txtpb.

.PARAMETER Check
    CI drift-check mode: regenerate to a temp file and exit non-zero if it
    differs from the committed golden. Does not modify working-tree files.

.EXAMPLE
    # Regenerate in-place
    .\tools\gen_edition_defaults.ps1

.EXAMPLE
    # CI drift check
    .\tools\gen_edition_defaults.ps1 -Check
#>
[CmdletBinding()]
param(
    [switch]$Check
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Paths (resolved relative to repo root = parent of this script's directory)
# ---------------------------------------------------------------------------
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot  = Split-Path -Parent $ScriptDir

$BinPb       = Join-Path $RepoRoot 'tests\editions\featureset_defaults.binpb'
$TxtPb       = Join-Path $RepoRoot 'tests\editions\golden\featureset_defaults.txtpb'
$VersionFile = Join-Path $RepoRoot 'tests\editions\golden\PROTOC_VERSION.txt'

$MinEdition = 'PROTO2'
$MaxEdition = '2023'

# ---------------------------------------------------------------------------
# Locate protoc and its include directory
# ---------------------------------------------------------------------------
$ProtocCmd = Get-Command protoc -ErrorAction SilentlyContinue
if ($null -eq $ProtocCmd) {
    Write-Error 'protoc not found on PATH'
    exit 1
}

$ProtocBin     = $ProtocCmd.Source
$ProtocVersion = (& protoc --version 2>&1)   # e.g. "libprotoc 28.2"

# Resolve the include dir containing google/protobuf/descriptor.proto.
# Tries (in order):
#   1. Standard layout: <protoc-dir>/../include  (unix installs, non-shim Windows)
#   2. Scoop current symlink:  $env:USERPROFILE\scoop\apps\protobuf\current\include
#   3. Scoop versioned dirs:   $env:USERPROFILE\scoop\apps\protobuf\*\include (newest first)
#   4. Common system paths (Chocolatey, manual installs)
$ProtocInclude   = $null
$DescriptorProto = $null

$Candidates = [System.Collections.Generic.List[string]]@(
    (Join-Path (Split-Path -Parent (Split-Path -Parent $ProtocBin)) 'include'),
    (Join-Path $env:USERPROFILE 'scoop\apps\protobuf\current\include'),
    'C:\ProgramData\chocolatey\lib\protoc\tools\include',
    'C:\tools\protoc\include'
)

$ScoopProtobufRoot = Join-Path $env:USERPROFILE 'scoop\apps\protobuf'
if (Test-Path $ScoopProtobufRoot) {
    Get-ChildItem -Path $ScoopProtobufRoot -Directory |
        Where-Object { $_.Name -ne 'current' } |
        Sort-Object Name -Descending |
        ForEach-Object { $Candidates.Add((Join-Path $_.FullName 'include')) }
}

foreach ($dir in $Candidates) {
    $probe = Join-Path $dir 'google\protobuf\descriptor.proto'
    if (Test-Path $probe) {
        $ProtocInclude   = $dir
        $DescriptorProto = $probe
        break
    }
}

if ($null -eq $ProtocInclude) {
    Write-Error "descriptor.proto not found in any known location.`nMake sure protoc's include directory is alongside its bin."
    exit 1
}

Write-Host "protoc:           $ProtocBin"
Write-Host "version:          $ProtocVersion"
Write-Host "include:          $ProtocInclude"
Write-Host "descriptor.proto: $DescriptorProto"
Write-Host "min edition:      $MinEdition   max edition: $MaxEdition"

# ---------------------------------------------------------------------------
# Helper: run protoc --edition_defaults_out
# ---------------------------------------------------------------------------
function Invoke-ProtocEditionDefaults {
    param([string]$OutBinPb)
    & protoc `
        "--proto_path=$ProtocInclude" `
        "--edition_defaults_out=$OutBinPb" `
        "--edition_defaults_minimum=$MinEdition" `
        "--edition_defaults_maximum=$MaxEdition" `
        $DescriptorProto
    if ($LASTEXITCODE -ne 0) {
        Write-Error "protoc failed with exit code $LASTEXITCODE"
        exit $LASTEXITCODE
    }
}

# ---------------------------------------------------------------------------
# Helper: decode binary -> text proto (piped through protoc --decode)
# ---------------------------------------------------------------------------
function ConvertFrom-BinPbToTxtPb {
    param([string]$InBinPb)
    $bytes = [System.IO.File]::ReadAllBytes($InBinPb)
    $txt = $bytes | & protoc `
        "--proto_path=$ProtocInclude" `
        '--decode=google.protobuf.FeatureSetDefaults' `
        $DescriptorProto 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Error "protoc --decode failed with exit code $LASTEXITCODE"
        exit $LASTEXITCODE
    }
    return $txt -join "`n"
}

# ---------------------------------------------------------------------------
# CHECK mode
# ---------------------------------------------------------------------------
if ($Check) {
    Write-Host ''
    Write-Host '=== CHECK MODE ==='
    $TmpDir  = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), [System.IO.Path]::GetRandomFileName())
    New-Item -ItemType Directory -Path $TmpDir | Out-Null
    try {
        $TmpBinPb = Join-Path $TmpDir 'featureset_defaults.binpb'
        Invoke-ProtocEditionDefaults -OutBinPb $TmpBinPb

        $committed  = [System.IO.File]::ReadAllBytes($BinPb)
        $regenerated = [System.IO.File]::ReadAllBytes($TmpBinPb)

        if ([System.Linq.Enumerable]::SequenceEqual($committed, $regenerated)) {
            Write-Host 'OK: regenerated binpb is byte-identical to committed golden.'
            exit 0
        } else {
            Write-Error "DRIFT DETECTED: regenerated binpb differs from committed golden.`n  committed : $BinPb`n  generated : $TmpBinPb`n`nRun  .\tools\gen_edition_defaults.ps1  to refresh the golden files."
            exit 1
        }
    } finally {
        Remove-Item -Recurse -Force $TmpDir -ErrorAction SilentlyContinue
    }
}

# ---------------------------------------------------------------------------
# GENERATE mode: write binary + text + version file in-place
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '=== GENERATE MODE ==='

Invoke-ProtocEditionDefaults -OutBinPb $BinPb
$binSize = (Get-Item $BinPb).Length
Write-Host "Written: $BinPb  ($binSize bytes)"

$GoldenDir = Split-Path -Parent $TxtPb
if (-not (Test-Path $GoldenDir)) { New-Item -ItemType Directory -Path $GoldenDir | Out-Null }

# Decode binary to text proto
$bytes = [System.IO.File]::ReadAllBytes($BinPb)
$txtLines = $bytes | & protoc `
    "--proto_path=$ProtocInclude" `
    '--decode=google.protobuf.FeatureSetDefaults' `
    $DescriptorProto 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Error "protoc --decode failed with exit code $LASTEXITCODE"
    exit $LASTEXITCODE
}
# Write with Unix line endings to match committed golden
$txtContent = ($txtLines -join "`n") + "`n"
[System.IO.File]::WriteAllText($TxtPb, $txtContent, [System.Text.UTF8Encoding]::new($false))
Write-Host "Written: $TxtPb"

# Write version file (Unix line endings)
$versionStr = $ProtocVersion -replace '^libprotoc ', ''
$versionContent = "protoc $versionStr (max edition $MaxEdition)`n$ProtocVersion`n"
[System.IO.File]::WriteAllText($VersionFile, $versionContent, [System.Text.UTF8Encoding]::new($false))
Write-Host "Written: $VersionFile"

Write-Host ''
Write-Host 'Done. Verify with: .\tools\gen_edition_defaults.ps1 -Check'
