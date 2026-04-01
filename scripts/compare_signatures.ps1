# Compare function signatures between original FFmpeg C files and Ball-compiled C++ files
# Usage: .\compare_signatures.ps1

param(
    [string]$OrigDir = "d:\packages\ball\ffmpeg",
    [string]$CompiledDir = "d:\packages\ball\ffmpeg_test_output\cpp_compiled",
    [string]$BallDir = "d:\packages\ball\ffmpeg_test_output\ball",
    [string]$OutputFile = "d:\packages\ball\ffmpeg_test_output\signature_comparison.csv"
)

$CLANG = "C:\Program Files\LLVM\bin\clang.exe"

function Extract-FunctionSignatures {
    param([string]$FilePath, [string]$Lang)
    
    $signatures = @()
    $content = Get-Content $FilePath -Raw -ErrorAction SilentlyContinue
    if (-not $content) { return $signatures }
    
    # Extract function definitions using regex (simplified but effective approach)
    # Matches: return_type function_name(params) {
    $pattern = '(?m)^(?:(?:static|inline|extern|const|unsigned|signed|long|short|volatile)\s+)*\w[\w\s\*]*\s+(\w+)\s*\(([^)]*)\)\s*\{'
    $matches = [regex]::Matches($content, $pattern)
    
    foreach ($m in $matches) {
        $funcName = $m.Groups[1].Value
        $params = $m.Groups[2].Value.Trim()
        # Skip common non-function patterns
        if ($funcName -in @("if", "while", "for", "switch", "return", "sizeof", "typeof")) { continue }
        $signatures += [PSCustomObject]@{
            Name = $funcName
            Params = $params
            Raw = $m.Value.TrimEnd('{').Trim()
        }
    }
    return $signatures
}

function Extract-BallFunctions {
    param([string]$BallJsonPath)
    
    $functions = @()
    try {
        $ball = Get-Content $BallJsonPath -Raw | ConvertFrom-Json
        foreach ($mod in $ball.modules) {
            if ($mod.name -eq "std" -or $mod.name -eq "cpp_std") { continue }
            foreach ($func in $mod.functions) {
                if ($func.is_base) { continue }
                $functions += [PSCustomObject]@{
                    Name = $func.name
                    InputType = $func.input_type
                    OutputType = $func.output_type
                    HasBody = ($null -ne $func.body)
                }
            }
        }
    } catch {
        # JSON parse error
    }
    return $functions
}

Write-Host "=== Signature Comparison ===" -ForegroundColor Cyan

$ballFiles = Get-ChildItem $BallDir -Filter "*.ball.json" -File -ErrorAction SilentlyContinue
if (-not $ballFiles) {
    Write-Host "No ball files found in $BallDir" -ForegroundColor Red
    exit 1
}

$results = @()
$totalMatches = 0
$totalMissing = 0
$totalExtra = 0

foreach ($ballFile in $ballFiles) {
    $safeName = $ballFile.BaseName -replace '\.ball$', ''
    $relPath = $safeName.Replace("_", "/") + ".c"
    
    # Find original file
    $origFile = Get-ChildItem $OrigDir -Recurse -Filter ($safeName.Split("_")[-1] + ".c") -File | Select-Object -First 1
    $compiledFile = Join-Path $CompiledDir "$safeName.cpp"
    
    if (-not $origFile -or -not (Test-Path $compiledFile)) { continue }
    
    # Extract Ball functions (source of truth for what the encoder captured)
    $ballFunctions = Extract-BallFunctions $ballFile.FullName
    
    # Extract signatures from original and compiled
    $origSigs = Extract-FunctionSignatures $origFile.FullName "c"
    $compiledSigs = Extract-FunctionSignatures $compiledFile "cpp"
    
    $origNames = $origSigs | ForEach-Object { $_.Name } | Sort-Object -Unique
    $compiledNames = $compiledSigs | ForEach-Object { $_.Name } | Sort-Object -Unique
    $ballNames = $ballFunctions | ForEach-Object { $_.Name } | Sort-Object -Unique
    
    # Compare: what was in original that's also in compiled?
    $matched = $origNames | Where-Object { $_ -in $compiledNames }
    $missing = $origNames | Where-Object { $_ -notin $compiledNames }
    $extra = $compiledNames | Where-Object { $_ -notin $origNames }
    
    $totalMatches += $matched.Count
    $totalMissing += $missing.Count
    $totalExtra += $extra.Count
    
    $results += [PSCustomObject]@{
        File = $relPath
        OrigFunctions = $origNames.Count
        BallFunctions = $ballNames.Count
        CompiledFunctions = $compiledNames.Count
        Matched = $matched.Count
        Missing = $missing.Count
        Extra = $extra.Count
        MissingNames = ($missing -join "; ")
    }
    
    if ($missing.Count -gt 0) {
        Write-Host "$relPath : $($matched.Count) matched, $($missing.Count) missing" -ForegroundColor Yellow
    } else {
        Write-Host "$relPath : $($matched.Count) matched, all preserved" -ForegroundColor Green
    }
}

# Summary
Write-Host ""
Write-Host "=== SIGNATURE SUMMARY ===" -ForegroundColor Cyan
Write-Host "Total matched:  $totalMatches"
Write-Host "Total missing:  $totalMissing" 
Write-Host "Total extra:    $totalExtra"
if (($totalMatches + $totalMissing) -gt 0) {
    $pct = [math]::Round(($totalMatches / ($totalMatches + $totalMissing)) * 100, 1)
    Write-Host "Match rate:     $pct%" -ForegroundColor $(if($pct -ge 90){"Green"}elseif($pct -ge 70){"Yellow"}else{"Red"})
}

$results | Export-Csv -Path $OutputFile -NoTypeInformation
Write-Host "Results saved to $OutputFile"
