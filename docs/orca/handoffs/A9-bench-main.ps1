# A9 evidence: runs this branch's bench_viewer_refresh.gd against another ref (default main),
# for the "before" numbers in docs/orca/handoffs/A9.md. That ref has no
# WorldState.get_view_snapshot(), so the copied bench's per-part split (_time_parts) is
# replaced by a no-op, and it has no ColonistPanel._visible_ids(), so on_screen_rows prints
# -1 there: only the timed boot._refresh() and the world swap are measured, exactly as on
# the branch (same window size, layout and scroll position). Uses a temporary detached worktree, removed afterwards.
# Usage (from the repo root): docs\orca\handoffs\A9-bench-main.ps1 [-Ref main] [-GodotPath <exe>]
[CmdletBinding()]
param(
    [string]$Ref = "main",
    [string]$GodotPath = ""
)

$ErrorActionPreference = "Continue"
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..\..")).Path
if (-not $GodotPath) { $GodotPath = $env:GODOT }
if (-not $GodotPath) { $GodotPath = "godot" }
$bench = Join-Path $repoRoot "game\scripts\tests\bench_viewer_refresh.gd"
$tree = Join-Path ([System.IO.Path]::GetTempPath()) ("a9-bench-" + [guid]::NewGuid().ToString("N").Substring(0, 8))

& git -C $repoRoot worktree add --detach $tree $Ref 2>&1 | Out-Null
try {
    $source = Get-Content -LiteralPath $bench -Raw
    $start = $source.IndexOf("func _time_parts")
    $end = $source.IndexOf("func _parse_args")
    $patched = $source.Substring(0, $start) + "func _time_parts(_boot: Node, _parts: Dictionary) -> void:`n`tpass`n`n" + $source.Substring($end)
    $visible = "boot._ui_scroll.colonist_panel._visible_ids().size()"
    if (-not $patched.Contains($visible)) { throw "A9-bench-main.ps1: the bench no longer reads $visible; update this script" }
    $patched = $patched.Replace($visible, "-1")
    $target = Join-Path $tree "game\scripts\tests\bench_viewer_refresh.gd"
    [System.IO.File]::WriteAllText($target, $patched)
    & $GodotPath --headless --path (Join-Path $tree "game") --import 2>&1 | Out-Null
    & $GodotPath --headless --path (Join-Path $tree "game") --script res://scripts/tests/bench_viewer_refresh.gd 2>&1 |
        ForEach-Object { "$_" } | Where-Object { $_ -match '^bench_viewer_refresh' }
} finally {
    & git -C $repoRoot worktree remove --force $tree 2>&1 | Out-Null
}
