#!/usr/bin/env pwsh
# Cross-language conformance test runner for the C++ Ball engine.
#
# Usage:
#   cd tests/conformance
#   pwsh run_conformance_cpp.ps1
#
# Requires: ball_cpp_runner built in cpp/build/engine/

param(
    [string]$EngineExe = "../../cpp/build/engine/Debug/ball_cpp_runner.exe",
    [string]$TestDir = "."
)

if (-not (Test-Path $EngineExe)) {
    # Try Release build
    $EngineExe = $EngineExe -replace "Debug", "Release"
    if (-not (Test-Path $EngineExe)) {
        Write-Error "C++ engine not found. Build it first: cd cpp/build && cmake .. && cmake --build ."
        exit 1
    }
}

$testFiles = Get-ChildItem -Path $TestDir -Filter "*.ball.json" | Sort-Object Name
if ($testFiles.Count -eq 0) {
    Write-Error "No .ball.json files found in $TestDir"
    exit 1
}

$passed = 0
$failed = 0
$skipped = 0
$failures = @()

foreach ($testFile in $testFiles) {
    $name = $testFile.Name -replace '\.ball\.json$', ''
    $expectedFile = Join-Path $TestDir "$name.expected_output.txt"

    if (-not (Test-Path $expectedFile)) {
        Write-Host "  SKIP $name (no expected output)"
        $skipped++
        continue
    }

    try {
        $output = & $EngineExe $testFile.FullName 2>$null
        # Join lines and trim trailing whitespace, filter out "Result:" lines
        $actualLines = ($output | Where-Object { $_ -notmatch '^Result:' }) -join "`n"
        $actual = $actualLines.TrimEnd()
        $expected = (Get-Content -Path $expectedFile -Raw).TrimEnd()

        if ($actual -eq $expected) {
            Write-Host "  PASS $name"
            $passed++
        } else {
            Write-Host "  FAIL $name"
            Write-Host "    Expected: $($expected -replace "`n", '\n')"
            Write-Host "    Actual:   $($actual -replace "`n", '\n')"
            $failures += $name
            $failed++
        }
    } catch {
        Write-Host "  ERROR $name`: $_"
        $failures += "$name (ERROR)"
        $failed++
    }
}

Write-Host ""
Write-Host "Results: $passed passed, $failed failed, $skipped skipped out of $($testFiles.Count) tests"

if ($failures.Count -gt 0) {
    Write-Host ""
    Write-Host "Failures:"
    foreach ($f in $failures) {
        Write-Host "  - $f"
    }
    exit 1
}
