# R0b evidence: a fresh worktree of the given commit stays clean after two imports and a boot.
# Usage (from the repo root): docs\orca\handoffs\R0b-verify.ps1 [-Ref HEAD]
# Run with -Ref main to see the old behaviour (31 *.png.import files reported as modified).
# Exits 1 if any Godot step fails or leaves the worktree dirty, 0 otherwise.
param([string]$Ref = "HEAD")

$ErrorActionPreference = "Continue"
$godot = $env:GODOT
if (-not $godot) { $godot = [Environment]::GetEnvironmentVariable("GODOT", "User") }
$dir = Join-Path ([System.IO.Path]::GetTempPath()) ("r0b-verify-" + [guid]::NewGuid().ToString("N").Substring(0, 8))

$failed = $false
git worktree add -q --detach $dir $Ref
if ($LASTEXITCODE -ne 0) { Write-Output "R0b-verify: could not create a worktree of '$Ref'"; exit 2 }
try {
    Push-Location $dir
    # Line endings of the *.import files as checked out (i/ = index, w/ = working tree).
    git ls-files --eol "game/*.import" | ForEach-Object { ($_ -split "\s+")[0..1] -join " " } |
        Group-Object | ForEach-Object { Write-Output ("{0,3} {1}" -f $_.Count, $_.Name) }
    foreach ($step in @("--import", "--import", "--quit-after 1")) {
        & $godot --headless --path game $step.Split(" ") *> $null
        $code = $LASTEXITCODE
        $dirty = @(git status --porcelain).Count
        Write-Output ("{0,-14} exit={1} dirty={2}" -f $step, $code, $dirty)
        if ($code -ne 0 -or $dirty -ne 0) { $failed = $true }
    }
} finally {
    Pop-Location
    git worktree remove --force $dir
}
if ($failed) { Write-Output "R0b-verify: FAIL"; exit 1 }
Write-Output "R0b-verify: PASS"
exit 0
