# Independent review of the current worktree against main, following docs/orca/REVIEW.md.
# Usage (from a terminal inside the task worktree): tools\orca\review.ps1 [-Agent codex|claude] [-Base origin/main] [-Effort high] [-NoSend] [-SkipPreflight]
# Preflight: refuses to start when the branch is behind origin/main or the handoff does not quote
# the suite line for the current test count (both would end as a REQUEST_CHANGES round anyway).
# Writes the verdict to .orca-review.md (git-ignored) and tries to hand it to the author's
# Claude terminal in the same Orca worktree.
[CmdletBinding()]
param(
    [ValidateSet("codex", "claude")][string]$Agent = "codex",
    [string]$Base = "origin/main",
    [switch]$NoSend,
    [ValidateSet("low", "medium", "high", "xhigh")][string]$Effort = "medium",   # codex reasoning effort; use high for core/scheduler/persistence changes
    [switch]$SkipPreflight   # skip the rebase/test-count preflight (debugging only)
)

$ErrorActionPreference = "Stop"
# git/orca print UTF-8; Windows PowerShell 5.1 would otherwise mangle paths with accents
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$root = (git rev-parse --show-toplevel 2>$null)
if (-not $root) { Write-Error "review: run this inside the task worktree"; exit 1 }
$root = (Resolve-Path $root).Path
Set-Location $root
$branch = git rev-parse --abbrev-ref HEAD
$taskId = ((($branch -split "/")[-1]) -split "-")[0].ToUpperInvariant()   # Orca may prefix the branch with the GitHub user

git fetch origin main --quiet
$changed = git diff --name-only "$Base...HEAD"
if (-not $changed) { Write-Output "review: no committed changes against $Base (is the work committed?)"; exit 1 }
Write-Output "review: $branch vs $Base — $(@($changed).Count) file(s) changed"

# Preflight (audit 2026-10-28): a third of the review rounds were "rebase onto main and refresh
# the test count". Refuse to start a review that would end that way and tell the author instead.
if (-not $SkipPreflight) {
    $problems = @()
    git merge-base --is-ancestor $Base HEAD 2>$null
    if ($LASTEXITCODE -ne 0) {
        $behind = (git rev-list --count "HEAD..$Base")
        $problems += "the branch is $behind commit(s) behind ${Base}: fetch + rebase, rerun the warnings gate and the full suite on the rebased head"
    }
    $branchTests = @(git ls-tree -r --name-only HEAD -- game/scripts/tests | Where-Object { $_ -match "/test_[^/]+\.gd$" }).Count
    $handoff = Join-Path $root "docs\orca\handoffs\$taskId.md"
    if (-not (Test-Path $handoff)) {
        $problems += "docs/orca/handoffs/$taskId.md is missing"
    } else {
        $quoted = [regex]::Matches((Get-Content -LiteralPath $handoff -Raw -Encoding UTF8), "all (\d+) test\(s\) PASS") | ForEach-Object { [int]$_.Groups[1].Value }
        if (-not $quoted) { $problems += "the handoff quotes no 'run_tests: all N test(s) PASS' line" }
        elseif (($quoted | Measure-Object -Maximum).Maximum -lt $branchTests) { $problems += "the handoff quotes $(($quoted | Measure-Object -Maximum).Maximum) tests but the branch has $branchTests test files: rerun the full suite on HEAD and quote its final line" }
    }
    if ($problems) {
        Write-Output "review: PREFLIGHT FAILED — not starting the reviewer:"
        $problems | ForEach-Object { Write-Output "  - $_" }
        if (-not $NoSend) {
            try {
                $terms = orca terminal list --worktree "path:$root" --json 2>$null | ConvertFrom-Json
                $list = @(); if ($terms.result.terminals) { $list = $terms.result.terminals } elseif ($terms.result) { $list = $terms.result }
                $target = $list | Where-Object { (($_ | ConvertTo-Json -Depth 5 -Compress).ToLowerInvariant()) -like "*claude*" } | Select-Object -First 1
                if ($target) {
                    $handle = $target.handle; if (-not $handle) { $handle = $target.id }
                    $msg = "Preflight de revision fallido (no se ha lanzado el revisor): " + ($problems -join "; ") + ". Corrigelo, actualiza el informe y haz commit; despues se lanza la revision."
                    orca terminal send --terminal $handle --text $msg --enter --json | Out-Null
                    Write-Output "review: preflight note sent to the author's terminal ($handle)"
                }
            } catch { }
        }
        exit 2
    }
    Write-Output "review: preflight ok (on top of $Base, $branchTests test files, handoff quotes the suite)"
}

$instructions = @"
You are the independent reviewer for branch '$branch' (backlog task $taskId) against $Base.
Read docs/orca/REVIEW.md and apply every check in it. Read the task entry '### $taskId' in
docs/orca/BACKLOG.md for the owned paths, acceptance and non-goals. The author's handoff
report is docs/orca/handoffs/$taskId.md (part of the diff). Do not edit any file.
Answer using exactly the verdict format from REVIEW.md, starting with 'VERDICT:'.
"@

$out = Join-Path $root ".orca-review.md"
$ErrorActionPreference = "Continue"   # the agents write progress to stderr; under "Stop" that would abort the script
if ($Agent -eq "codex") {
    # `codex review --base` does not accept custom instructions, so run a read-only exec with the
    # diff command spelled out; the sandbox forbids writes, so the reviewer cannot edit anything.
    $instructions += "`nThe diff to review: run 'git diff $Base...HEAD' (and 'git log $Base..HEAD') yourself."
    $text = "" | & codex exec --sandbox read-only --skip-git-repo-check -c "model_reasoning_effort=`"$Effort`"" $instructions 2>&1 | Out-String   # empty stdin: exec reads stdin when not a TTY
} else {
    $text = & claude -p --permission-mode plan "$instructions`n`nThe diff to review is: git diff $Base...HEAD" 2>&1 | Out-String
}
Set-Content -LiteralPath $out -Value $text -Encoding UTF8
Write-Output $text
Write-Output "review: verdict saved to .orca-review.md"

if ($NoSend) { exit 0 }

# Best effort: find the author's Claude terminal in this worktree and send it the follow-up.
try {
    $terms = orca terminal list --worktree "path:$root" --json 2>$null | ConvertFrom-Json
    $list = @()
    if ($terms.result.terminals) { $list = $terms.result.terminals } elseif ($terms.result) { $list = $terms.result }
    $target = $null
    foreach ($t in $list) {
        $blob = ($t | ConvertTo-Json -Depth 5 -Compress).ToLowerInvariant()
        if ($blob -like "*claude*") { $target = $t; break }
    }
    if ($target) {
        $handle = $target.handle; if (-not $handle) { $handle = $target.id }
        $msg = "Lee .orca-review.md (veredicto del revisor). Corrige todo lo bloqueante y lo no bloqueante que proceda, vuelve a pasar la suite completa, actualiza el informe de entrega y haz commit."
        orca terminal send --terminal $handle --text $msg --enter --json | Out-Null
        Write-Output "review: follow-up sent to the author's terminal ($handle)"
    } else {
        Write-Output "review: no Claude terminal found in this worktree; tell the author: 'Lee .orca-review.md y corrige lo que proceda'"
    }
} catch {
    Write-Output "review: could not reach Orca terminals ($($_.Exception.Message)); tell the author: 'Lee .orca-review.md y corrige lo que proceda'"
}
