# R13 evidence: boots the viewer from this checkout and from a temporary detached
# worktree of a base ref (default: main), and compares the printed boot hash and a
# windowed screenshot of the first screen (scripts/tools/screenshot.gd, 30 frames).
# Both runs share the same user:// directory, so they restore the same save (if any).
# Needs a desktop session (the screenshot is not headless).
# Usage: docs\orca\handoffs\R13-compare-boot.ps1 [-Base main] [-GodotPath <exe>]
[CmdletBinding()]
param([string]$Base = "main", [string]$GodotPath = "")

$ErrorActionPreference = "Continue"
if (-not $GodotPath) { $GodotPath = $env:GODOT }
if (-not $GodotPath) { $GodotPath = "godot" }
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..\..")).Path
$work = Join-Path ([System.IO.Path]::GetTempPath()) ("r13-compare-" + [guid]::NewGuid().ToString("N").Substring(0, 8))
$baseTree = Join-Path $work "base"
New-Item -ItemType Directory -Path $work | Out-Null

git -C $repoRoot worktree add --detach $baseTree $Base 2>&1 | Out-Null
$results = @{}
foreach ($side in @(@{ name = "base"; root = $baseTree }, @{ name = "branch"; root = $repoRoot })) {
    $game = Join-Path $side.root "game"
    $shots = Join-Path $work ("shots-" + $side.name)
    New-Item -ItemType Directory -Path $shots | Out-Null
    & $GodotPath --headless --path $game --import 2>&1 | Out-Null
    $hashLine = & $GodotPath --headless --path $game --quit-after 1 2>&1 | ForEach-Object { "$_" } | Where-Object { $_ -like "*boot hash*" }
    & $GodotPath --path $game --script res://scripts/tools/screenshot.gd -- $shots 2>&1 | Out-Null
    $png = Join-Path $shots "shot-1x.png"
    $sha = if (Test-Path $png) { (Get-FileHash -Algorithm SHA256 $png).Hash } else { "missing" }
    $results[$side.name] = @{ hash = "$hashLine"; sha = $sha }
    Write-Output ("{0,-6}  {1}  screenshot sha256 {2}" -f $side.name, $hashLine, $sha)
}
git -C $repoRoot worktree remove --force $baseTree 2>&1 | Out-Null
Remove-Item -Recurse -Force $work

$same = ($results.base.hash -eq $results.branch.hash) -and ($results.base.sha -eq $results.branch.sha) -and ($results.base.sha -ne "missing")
Write-Output ("R13 compare: " + $(if ($same) { "IDENTICAL boot hash and first screen" } else { "DIFFERENT" }))
if (-not $same) { exit 1 }
