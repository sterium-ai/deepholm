# Opens a backlog task as an Orca worktree with Claude Code inside and hands it the task.
# Usage: tools\orca\new-task.ps1 R1 [-Agent claude] [-NoActivate]
# Requires: Orca installed (orca.exe on PATH), the repo registered in Orca (tools\orca\setup.ps1).
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)][string]$TaskId,
    [string]$Agent = "claude",
    [switch]$NoActivate
)

$ErrorActionPreference = "Stop"
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$backlog = Join-Path $repoRoot "docs\orca\BACKLOG.md"

# Find the entry "### <id> — <title> · ..." and build a short kebab slug from the title.
$pattern = "^### $([regex]::Escape($TaskId))\s+[—-]\s+(.+?)\s+·"
$line = Get-Content -LiteralPath $backlog | Where-Object { $_ -match $pattern } | Select-Object -First 1
if (-not $line) {
    Write-Error "new-task: no entry '### $TaskId — ...' in docs/orca/BACKLOG.md"
    exit 1
}
$title = ([regex]::Match($line, $pattern)).Groups[1].Value
if ($title -match "Design:\s*\*pending\*" -or $line -match "Design:\s*\*pending\*") {
    Write-Error "new-task: $TaskId has its design pending; close the design questions in BACKLOG.md first"
    exit 1
}
$slug = ($title.ToLowerInvariant() -replace "[`'`"]", "" -replace "[^a-z0-9]+", "-").Trim("-")
$slug = ($slug -split "-" | Select-Object -First 4) -join "-"
$name = "$($TaskId.ToLowerInvariant())-$slug"

$status = orca status --json 2>$null | ConvertFrom-Json
if (-not $status.result.app.running) {
    Write-Output "new-task: starting Orca..."
    orca open --json | Out-Null
}

$prompt = "Lee AGENTS.md y docs/orca/README.md. Tu encargo es la tarea $TaskId de docs/orca/BACKLOG.md: lee la entrada completa (goal, owned paths, acceptance, non-goals) y hazla siguiendo docs/orca/REFACTOR-PLAN.md si es una tarea R. Primero importa el proyecto y pasa la suite completa con tools/run_tests.ps1 para tener la linea base. No toques nada fuera de los owned paths. Antes de entregar lee docs/orca/REVIEW.md y comprueba que todo lo que pide ya se cumple. Termina con el informe de entrega de AGENTS.md, incluyendo la linea final del runner de tests y las cifras de tools/measure_core.ps1, y actualiza la fila de estado de $TaskId en BACKLOG.md."

$args = @("worktree", "create", "--repo", "path:$repoRoot", "--name", $name, "--no-parent",
          "--agent", $Agent, "--prompt", $prompt, "--json")
if (-not $NoActivate) { $args += "--activate" }

Write-Output "new-task: creating worktree '$name' with $Agent..."
$raw = & orca @args 2>&1 | Out-String
try { $result = $raw | ConvertFrom-Json } catch { Write-Output $raw; exit 1 }
if (-not $result.ok) { Write-Output $raw; exit 1 }

$path = $result.result.worktree.path
if (-not $path) { $path = $result.result.path }
Write-Output "new-task: worktree ready at $path"
Write-Output "new-task: when $Agent reports done, open a terminal in that worktree and run tools\orca\review.ps1"
