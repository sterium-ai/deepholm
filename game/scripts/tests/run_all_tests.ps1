[CmdletBinding()]
param(
    [string]$GodotPath = "godot"
)

# Discovers every game/scripts/tests/test_*.gd file and runs each through
# Godot headless. Fails (non-zero exit) if any test's process exits non-zero
# or its stdout does not contain "<name>: PASS". Bash equivalent (used by CI):
# tools/run_tests.sh at the repository root.

$testsDir = $PSScriptRoot
$gameRoot = (Resolve-Path (Join-Path $testsDir '..\..')).Path
$testFiles = Get-ChildItem -Path $testsDir -Filter 'test_*.gd' | Sort-Object Name

if ($testFiles.Count -eq 0) {
    Write-Error 'run_all_tests: found no test_*.gd files to run.'
    exit 1
}

$failures = @()
foreach ($testFile in $testFiles) {
    $name = [System.IO.Path]::GetFileNameWithoutExtension($testFile.Name)
    $resPath = "res://scripts/tests/$($testFile.Name)"
    Write-Output "=== Running $name ==="
    $output = & $GodotPath --headless --path $gameRoot --script $resPath 2>&1
    $exitCode = $LASTEXITCODE
    $outputText = ($output | Out-String)
    Write-Output $outputText
    $expectedMarker = "${name}: PASS"
    if ($exitCode -ne 0 -or -not $outputText.Contains($expectedMarker)) {
        Write-Output "=== FAILED: $name (exit code $exitCode) ==="
        $failures += $name
    }
}

if ($failures.Count -gt 0) {
    Write-Error "run_all_tests: $($failures.Count) of $($testFiles.Count) test(s) failed: $($failures -join ', ')"
    exit 1
}

Write-Output "run_all_tests: all $($testFiles.Count) test(s) PASS"
exit 0
