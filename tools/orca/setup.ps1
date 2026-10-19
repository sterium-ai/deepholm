# One-time setup of this machine for the Orca workflow (idempotent).
# Usage: tools\orca\setup.ps1 [-GodotExe <path to Godot_v4.7.2-stable_win64_console.exe>]
[CmdletBinding()]
param([string]$GodotExe = "")

$ErrorActionPreference = "Stop"
# git/orca print UTF-8; Windows PowerShell 5.1 would otherwise mangle paths with accents
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path

# 1. Godot
if (-not $GodotExe) { $GodotExe = [Environment]::GetEnvironmentVariable("GODOT", "User") }
if (-not $GodotExe) {
    $candidates = @("C:\dev\Going Deeper\tools\godot\Godot_v4.7.2-stable_win64_console.exe", "C:\dev\tools\godot\Godot_v4.7.2-stable_win64_console.exe")
    $GodotExe = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
}
if (-not $GodotExe -or -not (Test-Path $GodotExe)) { Write-Error "setup: pass -GodotExe <path to the Godot 4.7.2 console exe>"; exit 1 }
[Environment]::SetEnvironmentVariable("GODOT", $GodotExe, "User")
$env:GODOT = $GodotExe
Write-Output "setup: GODOT = $GodotExe ($(& $GodotExe --version 2>$null | Select-Object -First 1))"

# 2. Tools on PATH check
foreach ($tool in @("orca", "claude", "codex", "gh", "git")) {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) { Write-Warning "setup: '$tool' not on PATH" } else { Write-Output "setup: $tool ok" }
}

# 3. Register the repo in Orca
$status = orca status --json 2>$null | ConvertFrom-Json
if (-not $status.result.app.running) { Write-Output "setup: starting Orca..."; orca open --json | Out-Null }
$repos = orca repo list --json 2>$null | ConvertFrom-Json
$want = $repoRoot.Replace("\\", "/").TrimEnd("/").ToLowerInvariant()
$known = @($repos.result.repos) + @($repos.result) | Where-Object { $_ -and ($_ | ConvertTo-Json -Compress).Replace("\\\\", "/").ToLowerInvariant() -like "*$want*" }
if (-not $known) {
    orca repo add --path $repoRoot --json | Out-String | Write-Output
} else { Write-Output "setup: repo already registered in Orca" }
try { orca repo set-base-ref --repo "path:$repoRoot" --ref "origin/main" --json | Out-Null; Write-Output "setup: base ref = origin/main" } catch { Write-Warning "setup: could not set base ref: $($_.Exception.Message)" }

Write-Output "setup: done. Restart Orca once so its terminals inherit GODOT, then: tools\orca\new-task.ps1 R1"
