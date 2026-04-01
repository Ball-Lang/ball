# FFmpeg → Ball → C++/Dart Pipeline
# Usage: .\process_ffmpeg.ps1 [-MaxFiles N] [-LibFilter "libavutil"]

param(
    [int]$MaxFiles = 0,
    [string]$LibFilter = "",
    [switch]$SkipEncode,
    [switch]$SkipCompileCpp,
    [switch]$SkipCompileDart
)

$ErrorActionPreference = "Continue"

# Paths
$BALL_ROOT     = "d:\packages\ball"
$FFMPEG_ROOT   = "$BALL_ROOT\ffmpeg"
$ENCODER       = "$BALL_ROOT\cpp\build\encoder\Release\ball_cpp_encode.exe"
$COMPILER_CPP  = "$BALL_ROOT\cpp\build\compiler\Release\ball_cpp_compile.exe"
$CLANG         = "C:\Program Files\LLVM\bin\clang.exe"
$OUTPUT_ROOT   = "$BALL_ROOT\ffmpeg_test_output"

# Output dirs
$AST_DIR       = "$OUTPUT_ROOT\ast"
$BALL_DIR      = "$OUTPUT_ROOT\ball"
$CPP_OUT_DIR   = "$OUTPUT_ROOT\cpp_compiled"
$DART_OUT_DIR  = "$OUTPUT_ROOT\dart_compiled"
$LOG_DIR       = "$OUTPUT_ROOT\logs"

# Create output directories
foreach ($dir in @($AST_DIR, $BALL_DIR, $CPP_OUT_DIR, $DART_OUT_DIR, $LOG_DIR)) {
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
}

# Gather source files
$sourceFiles = Get-ChildItem $FFMPEG_ROOT -Recurse -Include "*.c" -File
if ($LibFilter) {
    $sourceFiles = $sourceFiles | Where-Object { $_.FullName -like "*\$LibFilter\*" }
}
if ($MaxFiles -gt 0) {
    $sourceFiles = $sourceFiles | Select-Object -First $MaxFiles
}

$totalFiles = $sourceFiles.Count
Write-Host "=== FFmpeg Ball Pipeline ===" -ForegroundColor Cyan
Write-Host "Total .c files to process: $totalFiles"
Write-Host ""

# Counters
$astSuccess = 0; $astFail = 0
$encodeSuccess = 0; $encodeFail = 0
$compileCppSuccess = 0; $compileCppFail = 0

# Results tracking
$results = @()

$i = 0
foreach ($file in $sourceFiles) {
    $i++
    $relPath = $file.FullName.Substring($FFMPEG_ROOT.Length + 1).Replace("\", "/")
    $safeName = $relPath.Replace("/", "_").Replace(".c", "")
    
    Write-Host "[$i/$totalFiles] $relPath" -ForegroundColor Yellow -NoNewline

    $result = [PSCustomObject]@{
        File = $relPath
        AstOk = $false
        EncodeOk = $false
        CompileCppOk = $false
        Error = ""
    }

    # Step 1: Generate Clang AST JSON
    $astFile = "$AST_DIR\$safeName.ast.json"
    if (-not $SkipEncode) {
        $ffmpegIncludes = @(
            "-I$FFMPEG_ROOT",
            "-I$FFMPEG_ROOT\compat\atomics\win32"
        )
        
        # Add common FFmpeg include paths
        $libs = @("libavutil", "libavcodec", "libavformat", "libavfilter", "libswresample", "libswscale", "libavdevice", "fftools", "compat")
        foreach ($lib in $libs) {
            if (Test-Path "$FFMPEG_ROOT\$lib") {
                $ffmpegIncludes += "-I$FFMPEG_ROOT\$lib"
            }
        }

        $clangArgs = @(
            "-Xclang", "-ast-dump=json",
            "-fsyntax-only",
            "-w",
            "-std=c11",
            "-D__STDC_CONSTANT_MACROS",
            "-DHAVE_AV_CONFIG_H",
            "-D_CRT_SECURE_NO_WARNINGS",
            "-D_USE_MATH_DEFINES"
        ) + $ffmpegIncludes + @($file.FullName)

        try {
            $astOutput = & $CLANG @clangArgs 2>$null
            if ($LASTEXITCODE -eq 0 -and $astOutput) {
                $astOutput | Out-File -FilePath $astFile -Encoding utf8
                $result.AstOk = $true
                $astSuccess++
            } else {
                $result.Error = "clang ast failed (exit $LASTEXITCODE)"
                $astFail++
                Write-Host " [AST FAIL]" -ForegroundColor Red
                $results += $result
                continue
            }
        } catch {
            $result.Error = "clang exception: $_"
            $astFail++
            Write-Host " [AST EXCEPTION]" -ForegroundColor Red
            $results += $result
            continue
        }
    } else {
        if (Test-Path $astFile) { $result.AstOk = $true; $astSuccess++ }
    }

    # Step 2: Encode AST to Ball
    $ballFile = "$BALL_DIR\$safeName.ball.json"
    if (-not $SkipEncode -and $result.AstOk) {
        try {
            & $ENCODER $astFile $ballFile --normalize 2>"$LOG_DIR\encode_$safeName.err"
            if ($LASTEXITCODE -eq 0 -and (Test-Path $ballFile)) {
                $result.EncodeOk = $true
                $encodeSuccess++
            } else {
                $result.Error = "encode failed (exit $LASTEXITCODE)"
                $encodeFail++
                Write-Host " [ENCODE FAIL]" -ForegroundColor Red
                $results += $result
                continue
            }
        } catch {
            $result.Error = "encode exception: $_"
            $encodeFail++
            Write-Host " [ENCODE EXCEPTION]" -ForegroundColor Red
            $results += $result
            continue
        }
    }

    # Step 3: Compile Ball to C++
    $cppFile = "$CPP_OUT_DIR\$safeName.cpp"
    if (-not $SkipCompileCpp -and $result.EncodeOk) {
        try {
            & $COMPILER_CPP $ballFile $cppFile 2>"$LOG_DIR\compile_cpp_$safeName.err"
            if ($LASTEXITCODE -eq 0 -and (Test-Path $cppFile)) {
                $result.CompileCppOk = $true
                $compileCppSuccess++
            } else {
                $result.Error = "cpp compile failed (exit $LASTEXITCODE)"
                $compileCppFail++
            }
        } catch {
            $result.Error = "cpp compile exception: $_"
            $compileCppFail++
        }
    }

    if ($result.CompileCppOk) {
        Write-Host " [OK]" -ForegroundColor Green
    } elseif ($result.EncodeOk) {
        Write-Host " [COMPILE FAIL]" -ForegroundColor Red
    }
    
    $results += $result
}

# Summary
Write-Host ""
Write-Host "=== SUMMARY ===" -ForegroundColor Cyan
Write-Host "Files processed:     $totalFiles"
Write-Host "AST generation:      $astSuccess OK / $astFail FAIL" -ForegroundColor $(if($astFail -gt 0){"Yellow"}else{"Green"})
Write-Host "Ball encoding:       $encodeSuccess OK / $encodeFail FAIL" -ForegroundColor $(if($encodeFail -gt 0){"Yellow"}else{"Green"})
Write-Host "C++ compilation:     $compileCppSuccess OK / $compileCppFail FAIL" -ForegroundColor $(if($compileCppFail -gt 0){"Yellow"}else{"Green"})

# Save results
$results | Export-Csv -Path "$OUTPUT_ROOT\results.csv" -NoTypeInformation
Write-Host ""
Write-Host "Results saved to $OUTPUT_ROOT\results.csv"

# Save failures for analysis
$failures = $results | Where-Object { -not $_.CompileCppOk }
if ($failures.Count -gt 0) {
    $failures | Export-Csv -Path "$OUTPUT_ROOT\failures.csv" -NoTypeInformation
    Write-Host "Failures saved to $OUTPUT_ROOT\failures.csv"
}
