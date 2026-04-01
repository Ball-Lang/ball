# Process ALL FFmpeg C files - fast mode with timeout per file
# Usage: .\process_ffmpeg_all.ps1

param(
    [int]$TimeoutSec = 60,
    [switch]$SkipExisting
)

$ErrorActionPreference = "Continue"

$BALL_ROOT     = "d:\packages\ball"
$FFMPEG_ROOT   = "$BALL_ROOT\ffmpeg"
$ENCODER       = "$BALL_ROOT\cpp\build\encoder\Release\ball_cpp_encode.exe"
$COMPILER_CPP  = "$BALL_ROOT\cpp\build\compiler\Release\ball_cpp_compile.exe"
$CLANG         = "C:\Program Files\LLVM\bin\clang.exe"
$OUTPUT_ROOT   = "$BALL_ROOT\ffmpeg_test_output"

$AST_DIR       = "$OUTPUT_ROOT\ast"
$BALL_DIR      = "$OUTPUT_ROOT\ball"
$CPP_OUT_DIR   = "$OUTPUT_ROOT\cpp_compiled"
$LOG_DIR       = "$OUTPUT_ROOT\logs"

foreach ($dir in @($AST_DIR, $BALL_DIR, $CPP_OUT_DIR, $LOG_DIR)) {
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
}

# Include paths
$INCLUDES = @(
    "-I$FFMPEG_ROOT",
    "-I$FFMPEG_ROOT\libavutil",
    "-I$FFMPEG_ROOT\libavcodec",
    "-I$FFMPEG_ROOT\libavformat",
    "-I$FFMPEG_ROOT\libavfilter",
    "-I$FFMPEG_ROOT\libswresample",
    "-I$FFMPEG_ROOT\libswscale",
    "-I$FFMPEG_ROOT\libavdevice",
    "-I$FFMPEG_ROOT\fftools",
    "-I$FFMPEG_ROOT\compat"
)

$CLANG_BASE_ARGS = @(
    "-Xclang", "-ast-dump=json",
    "-fsyntax-only", "-w",
    "-std=c11",
    "-D__STDC_CONSTANT_MACROS",
    "-DHAVE_AV_CONFIG_H",
    "-D_CRT_SECURE_NO_WARNINGS",
    "-D_USE_MATH_DEFINES"
) + $INCLUDES

$sourceFiles = Get-ChildItem $FFMPEG_ROOT -Recurse -Include "*.c" -File
$totalFiles = $sourceFiles.Count

Write-Host "=== FFmpeg Full Pipeline ===" -ForegroundColor Cyan
Write-Host "Total .c files: $totalFiles"
Write-Host ""

$astOk = 0; $astFail = 0
$encOk = 0; $encFail = 0
$cppOk = 0; $cppFail = 0
$skipped = 0

$i = 0
foreach ($file in $sourceFiles) {
    $i++
    $relPath = $file.FullName.Substring($FFMPEG_ROOT.Length + 1).Replace("\", "/")
    $safeName = $relPath.Replace("/", "_").Replace(".c", "")
    
    $astFile = "$AST_DIR\$safeName.ast.json"
    $ballFile = "$BALL_DIR\$safeName.ball.json"
    $cppFile = "$CPP_OUT_DIR\$safeName.cpp"

    # Skip existing successes
    if ($SkipExisting -and (Test-Path $cppFile)) {
        $skipped++
        $astOk++; $encOk++; $cppOk++
        continue
    }

    # Progress every 50 files
    if ($i % 50 -eq 0) {
        Write-Host "  [$i/$totalFiles] ast=$astOk enc=$encOk cpp=$cppOk fail(a=$astFail e=$encFail c=$cppFail)" -ForegroundColor DarkGray
    }

    # Step 1: Clang AST
    if (-not (Test-Path $astFile) -or -not $SkipExisting) {
        try {
            $proc = Start-Process -FilePath $CLANG -ArgumentList ($CLANG_BASE_ARGS + @($file.FullName)) -RedirectStandardOutput $astFile -RedirectStandardError "$LOG_DIR\ast_$safeName.err" -PassThru -NoNewWindow -Wait
            if ($proc.ExitCode -ne 0 -or (Get-Item $astFile -ErrorAction SilentlyContinue).Length -lt 100) {
                $astFail++
                continue
            }
            $astOk++
        } catch {
            $astFail++
            continue
        }
    } else {
        $astOk++
    }

    # Step 2: Encode
    try {
        $proc = Start-Process -FilePath $ENCODER -ArgumentList @($astFile, $ballFile, "--normalize") -RedirectStandardError "$LOG_DIR\enc_$safeName.err" -PassThru -NoNewWindow -Wait
        if ($proc.ExitCode -ne 0 -or -not (Test-Path $ballFile)) {
            $encFail++
            continue
        }
        $encOk++
    } catch {
        $encFail++
        continue
    }

    # Step 3: Compile to C++
    try {
        $proc = Start-Process -FilePath $COMPILER_CPP -ArgumentList @($ballFile, $cppFile) -RedirectStandardError "$LOG_DIR\cpp_$safeName.err" -PassThru -NoNewWindow -Wait
        if ($proc.ExitCode -ne 0 -or -not (Test-Path $cppFile)) {
            $cppFail++
            continue
        }
        $cppOk++
    } catch {
        $cppFail++
        continue
    }
}

Write-Host ""
Write-Host "=== FULL PIPELINE SUMMARY ===" -ForegroundColor Cyan
Write-Host "Total .c files:       $totalFiles"
Write-Host "Skipped (existing):   $skipped"
Write-Host "AST parse:            $astOk OK / $astFail FAIL"
Write-Host "Ball encode:          $encOk OK / $encFail FAIL"
Write-Host "C++ compile:          $cppOk OK / $cppFail FAIL"
Write-Host ""

$astPct = if($totalFiles -gt 0){[math]::Round(($astOk/$totalFiles)*100,1)}else{0}
$encPct = if($astOk -gt 0){[math]::Round(($encOk/$astOk)*100,1)}else{0}
$cppPct = if($encOk -gt 0){[math]::Round(($cppOk/$encOk)*100,1)}else{0}
$e2ePct = if($totalFiles -gt 0){[math]::Round(($cppOk/$totalFiles)*100,1)}else{0}

Write-Host "AST success rate:     $astPct%"
Write-Host "Encode success rate:  $encPct% (of AST successes)"
Write-Host "Compile success rate: $cppPct% (of encode successes)"
Write-Host "End-to-end rate:      $e2ePct%"

# Write summary to file
@"
FFmpeg Ball Pipeline Results
============================
Date: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
Total .c files: $totalFiles
AST parse: $astOk OK / $astFail FAIL ($astPct%)
Ball encode: $encOk OK / $encFail FAIL ($encPct% of AST)
C++ compile: $cppOk OK / $cppFail FAIL ($cppPct% of encoded)
End-to-end: $cppOk / $totalFiles ($e2ePct%)
"@ | Out-File "$OUTPUT_ROOT\summary.txt"

Write-Host "Summary saved to $OUTPUT_ROOT\summary.txt"
