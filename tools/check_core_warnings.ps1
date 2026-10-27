# Counts the GDScript analyzer warnings under game/scripts/core and fails when any kind rises
# above docs/architecture/warnings-baseline.txt. Lower counts pass; rerun with -Update to lower
# the baseline in the same change. The warning switches live in game/project.godot ([debug]).
# Usage: tools\check_core_warnings.ps1 [-GodotPath <exe>] [-Update] [-SkipImport]
# Godot is taken from -GodotPath, then $env:GODOT, then "godot" on PATH.
[CmdletBinding()]
param(
    [string]$GodotPath = "",
    [switch]$Update,
    [switch]$SkipImport
)

$ErrorActionPreference = "Continue"
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$gameRoot = Join-Path $repoRoot "game"
$probe = Join-Path $PSScriptRoot "core_warnings_probe.gd"
$baselinePath = Join-Path $repoRoot "docs\architecture\warnings-baseline.txt"
$kinds = @("untyped_declaration", "unsafe_property_access", "unsafe_method_access", "unsafe_call_argument", "other")

if (-not $GodotPath) { $GodotPath = $env:GODOT }
if (-not $GodotPath) { $GodotPath = "godot" }
if (-not (Get-Command $GodotPath -ErrorAction SilentlyContinue)) {
    Write-Output "check_core_warnings: Godot not found ('$GodotPath'). Set `$env:GODOT to the 4.7.2 console executable."
    exit 2
}

if (-not $SkipImport) {
    & $GodotPath --headless --path $gameRoot --import 2>&1 | Out-Null
}

$expectedScripts = (Get-ChildItem -Path (Join-Path $gameRoot "scripts\core") -Recurse -Filter "*.gd").Count
# Exits 1, after printing the errors, unless the probe compiled every core script cleanly.
function Assert-ProbeRun($lines, $exitCode) {
    $loaded = $lines | Where-Object { $_ -match '^core_warnings_probe: loaded (\d+) script' } | ForEach-Object { [int]$Matches[1] }
    $errors = @($lines | Where-Object { $_ -match '^SCRIPT ERROR' })
    if ($exitCode -eq 0 -and $loaded -eq $expectedScripts -and $errors.Count -eq 0) { return }
    $lines | Where-Object { $_ -match '^(core_warnings_probe|SCRIPT ERROR|ERROR)' } | Write-Output
    Write-Output "check_core_warnings: probe failed (exit $exitCode, loaded '$loaded' of $expectedScripts core scripts)"
    exit 1
}

# Pass 1, no debugger: every core script must compile. With -d a script error stops at the
# debugger prompt and waits for input, so errors are caught here first.
$output = & $GodotPath --headless --path $gameRoot --script $probe 2>&1 | ForEach-Object { "$_" }
Assert-ProbeRun $output $LASTEXITCODE

# Pass 2: -d attaches the local debugger; without one, Godot compiles scripts without reporting
# warnings. "q" on stdin quits the debugger prompt should a runtime error still reach it.
$output = "q`nq`n" | & $GodotPath --headless -d --path $gameRoot --script $probe 2>&1 | ForEach-Object { "$_" }
Assert-ProbeRun $output $LASTEXITCODE
$version = (& $GodotPath --version 2>&1 | Select-Object -First 1)
# The probe declares one untyped variable on purpose: if its warning is missing, warnings are not
# being reported at all and a zero count would mean nothing.
if (-not ($output | Where-Object { $_ -match 'Variable "_warning_canary" has no static type' })) {
    Write-Output "check_core_warnings: the probe's canary warning was not printed; warnings are not being reported"
    exit 1
}

$counts = @{}; foreach ($k in $kinds) { $counts[$k] = 0 }
$perFile = @{}
for ($i = 0; $i -lt $output.Count - 1; $i++) {
    if (-not $output[$i].StartsWith("WARNING: ")) { continue }
    if ($output[$i + 1] -notmatch 'at: GDScript::reload \(res://(scripts/core/[^:]+\.gd):\d+\)') { continue }
    $file = "game/" + $Matches[1]
    $message = $output[$i]
    $kind = "other"
    if ($message -match 'has no static (return )?type') { $kind = "untyped_declaration" }
    elseif ($message -match 'The property ".*" is not present on the inferred type') { $kind = "unsafe_property_access" }
    elseif ($message -match 'The method ".*" is not present on the inferred type') { $kind = "unsafe_method_access" }
    elseif ($message -match 'requires the subtype') { $kind = "unsafe_call_argument" }
    $counts[$kind]++
    $perFile[$file] = 1 + [int]$perFile[$file]
}
$total = 0; foreach ($k in $kinds) { $total += $counts[$k] }

if ($Update) {
    $lines = @(
        "# GDScript warnings under game/scripts/core, by kind. CI fails when a count rises above this.",
        "# Regenerate with tools\check_core_warnings.ps1 -Update (only ever to lower it, or with an ADR).",
        "# $version",
        "total $total"
    )
    foreach ($k in $kinds) { $lines += "$k $($counts[$k])" }
    $lines += "# Per file, for reference only (not gated, so moving code between files needs no update):"
    foreach ($f in ($perFile.Keys | Sort-Object)) { $lines += "file $f $($perFile[$f])" }
    [System.IO.File]::WriteAllText($baselinePath, (($lines -join "`n") + "`n"), (New-Object System.Text.UTF8Encoding $false))
    Write-Output "check_core_warnings: baseline written, total $total"
    exit 0
}

if (-not (Test-Path $baselinePath)) { Write-Output "check_core_warnings: no baseline at $baselinePath (run with -Update)"; exit 1 }
$baseline = @{}; $baseFile = @{}
foreach ($line in Get-Content -LiteralPath $baselinePath) {
    if ($line -match '^file (\S+) (\d+)$') { $baseFile[$Matches[1]] = [int]$Matches[2] }
    elseif ($line -match '^(\w+) (\d+)$') { $baseline[$Matches[1]] = [int]$Matches[2] }
}

$risen = @()
foreach ($k in $kinds + @("total")) {
    $now = if ($k -eq "total") { $total } else { $counts[$k] }
    $was = [int]$baseline[$k]
    Write-Output ("{0,-24} {1,6} (baseline {2})" -f $k, $now, $was)
    if ($now -gt $was) { $risen += $k }
}
if ($risen.Count -gt 0) {
    foreach ($f in ($perFile.Keys | Sort-Object)) {
        $was = [int]$baseFile[$f]
        if ($perFile[$f] -gt $was) { Write-Output ("  {0}: {1} (baseline {2})" -f $f, $perFile[$f], $was) }
    }
    Write-Output "check_core_warnings: FAIL, warnings rose: $($risen -join ', ')"
    exit 1
}
if ($total -lt [int]$baseline["total"]) {
    Write-Output "check_core_warnings: below baseline; lower it with -Update in this change"
}
Write-Output "check_core_warnings: OK, $total warning(s), none above baseline"
exit 0
