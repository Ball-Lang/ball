<# 
.SYNOPSIS
    Process FFmpeg C files through the Ball pipeline with binary protobuf support.
    Pipeline: C → Clang AST → Ball IR (binary) → C++ / Dart

.DESCRIPTION
    Uses binary protobuf format (.ball.pb) between encoder and compiler
    to avoid JSON depth limit issues. Also outputs .ball.json for Dart compilation.
#>

param(
    [string]$FfmpegDir = "d:\packages\ball\ffmpeg",
    [string]$OutputDir = "d:\packages\ball\ffmpeg_test_output",
    [int]$MaxFiles = 0,
    [switch]$SkipExisting
)

$ErrorActionPreference = "Continue"

$encoder  = "d:\packages\ball\cpp\build\encoder\Release\ball_cpp_encode.exe"
$compiler = "d:\packages\ball\cpp\build\compiler\Release\ball_cpp_compile.exe"
$clang    = "C:\Program Files\LLVM\bin\clang.exe"

# Verify tools exist
foreach ($tool in @($encoder, $compiler, $clang)) {
    if (-not (Test-Path $tool)) {
        Write-Error "Tool not found: $tool"
        exit 1
    }
}

# Create output directories
$astDir      = "$OutputDir\ast"
$ballJsonDir = "$OutputDir\ball"
$ballBinDir  = "$OutputDir\ball_bin"
$cppDir      = "$OutputDir\cpp_compiled"
$errDir      = "$OutputDir\errors"

foreach ($d in @($astDir, $ballJsonDir, $ballBinDir, $cppDir, $errDir)) {
    New-Item -ItemType Directory -Force -Path $d | Out-Null
}

# Create FFmpeg config stubs if needed
$configH = "$FfmpegDir\config.h"
if (-not (Test-Path $configH)) {
    @"
#ifndef FFMPEG_CONFIG_H
#define FFMPEG_CONFIG_H
#define ARCH_X86 1
#define ARCH_X86_64 1
#define HAVE_INLINE_ASM 0
#define HAVE_X86ASM 0
#define HAVE_MMX 0
#define HAVE_SSE 0
#define HAVE_FAST_64BIT 1
#define HAVE_THREADS 1
#define HAVE_PTHREADS 0
#define HAVE_W32THREADS 1
#define restrict
#define HAVE_BIGENDIAN 0
#define HAVE_FAST_UNALIGNED 1
#define CONFIG_SMALL 0
#define CONFIG_GPL 1
#define FFMPEG_CONFIGURATION ""
#define CC_IDENT "clang"
#define av_restrict restrict
#endif
"@ | Set-Content $configH
}

$avConfig = "$FfmpegDir\libavutil\avconfig.h"
if (-not (Test-Path $avConfig)) {
    @"
#ifndef AVUTIL_AVCONFIG_H
#define AVUTIL_AVCONFIG_H
#define AV_HAVE_BIGENDIAN 0
#define AV_HAVE_FAST_UNALIGNED 1
#endif
"@ | Set-Content $avConfig
}

$compConfig = "$FfmpegDir\config_components.h"
if (-not (Test-Path $compConfig)) {
    @"
#ifndef CONFIG_COMPONENTS_H
#define CONFIG_COMPONENTS_H
#define CONFIG_H264_DECODER 1
#define CONFIG_AAC_DECODER 1
#define CONFIG_MP3_DECODER 1
#define CONFIG_MPEG4_DECODER 1
#define CONFIG_VP9_DECODER 1
#define CONFIG_AV1_DECODER 1
#define CONFIG_H264_ENCODER 1
#define CONFIG_AAC_ENCODER 1
#endif
"@ | Set-Content $compConfig
}

# Gather C files
$cFiles = Get-ChildItem "$FfmpegDir" -Filter "*.c" -Recurse -File |
    Where-Object { $_.FullName -notmatch "\\(\.git|build|doc[\\/]examples)" } |
    Sort-Object FullName

if ($MaxFiles -gt 0) { $cFiles = $cFiles | Select-Object -First $MaxFiles }
$total = $cFiles.Count

Write-Host "=== Ball FFmpeg Pipeline (Binary Protobuf) ==="
Write-Host "FFmpeg dir: $FfmpegDir"
Write-Host "Output dir: $OutputDir"
Write-Host "Total .c files: $total"
Write-Host ""

$astOk = 0; $astFail = 0
$encOk = 0; $encFail = 0
$compOk = 0; $compFail = 0
$skipped = 0

$sw = [System.Diagnostics.Stopwatch]::StartNew()

for ($i = 0; $i -lt $cFiles.Count; $i++) {
    $f = $cFiles[$i]
    $rel = $f.FullName.Substring($FfmpegDir.Length + 1) -replace "[/\\]","_" -replace "\.c$",""
    
    $astFile      = "$astDir\${rel}.ast.json"
    $ballJsonFile = "$ballJsonDir\${rel}.ball.json"
    $ballBinFile  = "$ballBinDir\${rel}.ball.pb"
    $cppFile      = "$cppDir\${rel}.cpp"

    # Skip if all outputs exist
    if ($SkipExisting -and (Test-Path $cppFile)) {
        $skipped++
        continue
    }

    # --- Stage 1: Clang AST ---
    if (-not (Test-Path $astFile) -or (Get-Item $astFile).Length -lt 100) {
        $proc = Start-Process -FilePath $clang -ArgumentList @(
            "-Xclang", "-ast-dump=json",
            "-fsyntax-only",
            "-I$FfmpegDir",
            "-I$FfmpegDir\libavutil",
            "-I$FfmpegDir\libavcodec",
            "-I$FfmpegDir\libavformat",
            "-I$FfmpegDir\libswscale",
            "-I$FfmpegDir\libswresample",
            "-I$FfmpegDir\libavfilter",
            "-w",
            $f.FullName
        ) -NoNewWindow -Wait -PassThru `
          -RedirectStandardOutput $astFile `
          -RedirectStandardError "$errDir\ast_${rel}.txt"
        
        if ($proc.ExitCode -ne 0 -or (Get-Item $astFile -ErrorAction SilentlyContinue).Length -lt 100) {
            $astFail++
            Remove-Item $astFile -ErrorAction SilentlyContinue
            continue
        }
    }
    $astOk++

    # --- Stage 2: Encode to Ball (both JSON and binary) ---
    if (-not (Test-Path $ballBinFile) -or (Get-Item $ballBinFile).Length -lt 10) {
        # Binary output
        $proc = Start-Process -FilePath $encoder -ArgumentList @(
            $astFile, $ballBinFile, "--normalize", "--binary"
        ) -NoNewWindow -Wait -PassThru `
          -RedirectStandardOutput "NUL" `
          -RedirectStandardError "$errDir\encode_bin_${rel}.txt"
        
        if ($proc.ExitCode -ne 0 -or (Get-Item $ballBinFile -ErrorAction SilentlyContinue).Length -lt 10) {
            $encFail++
            Remove-Item $ballBinFile -ErrorAction SilentlyContinue
            continue
        }
    }

    # Also produce JSON for Dart (skip during main pipeline — run separately)
    # if (-not (Test-Path $ballJsonFile) -or (Get-Item $ballJsonFile).Length -lt 100) {
    #     $proc2 = Start-Process -FilePath $encoder -ArgumentList @(
    #         $astFile, $ballJsonFile, "--normalize"
    #     ) -NoNewWindow -Wait -PassThru `
    #       -RedirectStandardOutput "NUL" `
    #       -RedirectStandardError "$errDir\encode_json_${rel}.txt"
    #     # JSON failures are acceptable — binary is the primary path
    # }
    $encOk++

    # --- Stage 3: Compile Ball (binary) to C++ ---
    $proc = Start-Process -FilePath $compiler -ArgumentList @(
        $ballBinFile, $cppFile
    ) -NoNewWindow -Wait -PassThru `
      -RedirectStandardOutput "NUL" `
      -RedirectStandardError "$errDir\compile_${rel}.txt"
    
    if ($proc.ExitCode -ne 0 -or (Get-Item $cppFile -ErrorAction SilentlyContinue).Length -lt 50) {
        $compFail++
        Remove-Item $cppFile -ErrorAction SilentlyContinue
    } else {
        $compOk++
    }

    # Progress
    if ((($i + 1) % 100) -eq 0 -or $i -eq $cFiles.Count - 1) {
        $elapsed = $sw.Elapsed.ToString("hh\:mm\:ss")
        $rate = [math]::Round(($i + 1) / $sw.Elapsed.TotalSeconds, 1)
        Write-Host "  [$($i+1)/$total] AST:$astOk/$astFail  Enc:$encOk/$encFail  Cpp:$compOk/$compFail  ($elapsed, ${rate}/s)"
    }
}

$sw.Stop()

# Summary
$summary = @"

=== FULL PIPELINE SUMMARY ===
Total .c files:       $total
Skipped (existing):   $skipped
AST parse:            $astOk OK / $astFail FAIL
Ball encode:          $encOk OK / $encFail FAIL
C++ compile:          $compOk OK / $compFail FAIL

AST success rate:     $([math]::Round($astOk/[math]::Max(1,$total)*100, 1))%
Encode success rate:  $([math]::Round($encOk/[math]::Max(1,$astOk)*100, 1))% (of AST successes)
Compile success rate: $([math]::Round($compOk/[math]::Max(1,$encOk)*100, 1))% (of encode successes)
End-to-end rate:      $([math]::Round($compOk/[math]::Max(1,$total)*100, 1))%
Elapsed:              $($sw.Elapsed.ToString("hh\:mm\:ss"))
"@

Write-Host $summary
$summary | Set-Content "$OutputDir\summary.txt"
Write-Host "Summary saved to $OutputDir\summary.txt"
