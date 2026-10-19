# Pushes the current task branch and opens (or updates) its pull request.
# Usage (inside the task worktree): tools\orca\ship.ps1 [-AutoMerge]
# CI (GitHub Actions, Windows) runs the full headless suite on the PR. Merge from Orca's PR tab
# or with `gh pr merge --squash` once it is green. -AutoMerge asks GitHub to squash-merge
# automatically when checks pass (needs branch protection on main; harmless otherwise).
[CmdletBinding()]
param([switch]$AutoMerge)

$ErrorActionPreference = "Stop"
$root = (git rev-parse --show-toplevel 2>$null)
if (-not $root) { Write-Error "ship: run this inside the task worktree"; exit 1 }
Set-Location $root
$branch = git rev-parse --abbrev-ref HEAD
if ($branch -eq "main") { Write-Error "ship: you are on main"; exit 1 }
if (git status --porcelain) { Write-Error "ship: uncommitted changes; ask the author to commit first"; exit 1 }

git push -u origin $branch
$existing = gh pr view --json url --jq .url 2>$null
if ($existing) {
    Write-Output "ship: PR already open: $existing"
} else {
    $title = (git log -1 --pretty=%s)
    $body = (git log "origin/main..HEAD" --pretty="- %s%n%n%b") -join "`n"
    gh pr create --base main --head $branch --title $title --body $body
    $existing = gh pr view --json url --jq .url
    Write-Output "ship: PR created: $existing"
}
if ($AutoMerge) {
    try { gh pr merge --squash --auto 2>&1 | Out-String | Write-Output } catch { Write-Output "ship: auto-merge not available ($($_.Exception.Message)); merge by hand when CI is green" }
}
Write-Output "ship: wait for 'Godot headless checks' to pass, then merge (Orca PR tab or: gh pr merge --squash) and delete the worktree in Orca."
