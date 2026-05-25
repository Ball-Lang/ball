# Configure and build the C++ tree with Ninja for parallel TU compilation.
# Requires: cmake, Ninja (ninja.exe on PATH), MSVC or clang-cl toolchain.
param(
    [ValidateSet("Release", "Debug")]
    [string]$Config = "Release",
    [string]$Preset = "ninja-release"
)
$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$Cpp = Join-Path $Root "cpp"
if ($Config -eq "Debug") { $Preset = "ninja-debug" }

Push-Location $Cpp
try {
    cmake --preset $Preset
    cmake --build --preset $Preset --target test_selfhost_conformance
} finally {
    Pop-Location
}
