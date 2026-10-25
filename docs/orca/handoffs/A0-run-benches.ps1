# Runs every A0 benchmark (game/scripts/tests/bench_*.gd except bench_common.gd)
# headless, one after another, and keeps only the "bench_*:" result lines.
# Usage: docs\orca\handoffs\A0-run-benches.ps1 [-GodotPath <exe>] [-Out <file>] [-Filter <name>]
# Godot is taken from -GodotPath, then $env:GODOT. Run nothing else heavy meanwhile:
# the numbers are wall-clock timings.
[CmdletBinding()]
param(
    [string]$GodotPath = "",
    [string]$Out = "",
    [string]$Filter = ""
)

$ErrorActionPreference = "Continue"
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..\..")).Path
$gameRoot = Join-Path $repoRoot "game"
if (-not $GodotPath) { $GodotPath = $env:GODOT }
if (-not $GodotPath) { Write-Output "A0-run-benches: set `$env:GODOT or pass -GodotPath"; exit 2 }

& $GodotPath --headless --path $gameRoot --import 2>&1 | Out-Null
$benches = Get-ChildItem -Path (Join-Path $gameRoot "scripts\tests") -Filter "bench_*.gd" |
    Where-Object { $_.Name -ne "bench_common.gd" } | Sort-Object Name
if ($Filter) { $benches = $benches | Where-Object { $_.Name -like "*$Filter*" } }
$lines = @()
foreach ($bench in $benches) {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $output = & $GodotPath --headless --path $gameRoot --script "res://scripts/tests/$($bench.Name)" 2>&1 | ForEach-Object { "$_" }
    $sw.Stop()
    $kept = $output | Where-Object { $_ -match '^bench_' }
    $kept += ("{0}: wall={1:n0}s exit={2}" -f $bench.BaseName, $sw.Elapsed.TotalSeconds, $LASTEXITCODE)
    $kept | ForEach-Object { Write-Output $_ }
    $lines += $kept
}
if ($Out) { $lines | Set-Content -Path $Out -Encoding utf8 }
