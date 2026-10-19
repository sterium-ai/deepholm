# Runs the headless Godot test suite on Windows.
# Usage: tools\run_tests.ps1 [-Filter <substring>] [-GodotPath <exe>] [-SkipImport]
# Godot is taken from -GodotPath, then $env:GODOT, then "godot" on PATH.
[CmdletBinding()]
param(
    [string]$Filter = "",
    [string]$GodotPath = "",
    [switch]$SkipImport
)

# Godot writes warnings to stderr; "Continue" keeps 2>&1 from turning them into terminating errors.
$ErrorActionPreference = "Continue"
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$gameRoot = Join-Path $repoRoot "game"
$testsDir = Join-Path $gameRoot "scripts\tests"

if (-not $GodotPath) { $GodotPath = $env:GODOT }
if (-not $GodotPath) { $GodotPath = "godot" }
if (-not (Get-Command $GodotPath -ErrorAction SilentlyContinue)) {
    Write-Output "run_tests: Godot not found ('$GodotPath'). Set `$env:GODOT to the 4.7.2 console executable."
    exit 2
}

if (-not $SkipImport) {
    Write-Output "=== Importing project (class cache) ==="
    & $GodotPath --headless --path $gameRoot --import 2>&1 | Out-Null
}

$testFiles = Get-ChildItem -Path $testsDir -Filter "test_*.gd" | Sort-Object Name
if ($Filter) { $testFiles = $testFiles | Where-Object { $_.Name -like "*$Filter*" } }
if ($testFiles.Count -eq 0) { Write-Output "run_tests: no test files match '$Filter'"; exit 1 }

$failures = @()
$sw = [System.Diagnostics.Stopwatch]::StartNew()
foreach ($testFile in $testFiles) {
    $name = [System.IO.Path]::GetFileNameWithoutExtension($testFile.Name)
    $resPath = "res://scripts/tests/$($testFile.Name)"
    Write-Output "=== Running $name ==="
    $output = & $GodotPath --headless --path $gameRoot --script $resPath 2>&1 | ForEach-Object { "$_" }
    $exitCode = $LASTEXITCODE
    $text = ($output | Out-String)
    Write-Output $text
    if ($exitCode -ne 0 -or -not $text.Contains("${name}: PASS")) {
        Write-Output "=== FAILED: $name (exit code $exitCode) ==="
        $failures += $name
    }
}
$sw.Stop()

if ($failures.Count -gt 0) {
    Write-Output ("run_tests: {0} of {1} test(s) failed: {2}  [{3:n0}s]" -f $failures.Count, $testFiles.Count, ($failures -join ", "), $sw.Elapsed.TotalSeconds)
    exit 1
}
Write-Output ("run_tests: all {0} test(s) PASS  [{1:n0}s]" -f $testFiles.Count, $sw.Elapsed.TotalSeconds)
exit 0
