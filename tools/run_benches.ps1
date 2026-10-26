# Runs every headless benchmark (game/scripts/tests/bench_*.gd except bench_common.gd)
# one after another, prints their "bench_*:" result lines, and writes the Markdown
# baseline report (docs/architecture/bench-baseline.md by default): commit and host in
# the header, then one section per benchmark with its tables (built from the "@row"
# lines each benchmark prints) and its raw lines.
# Usage: tools\run_benches.ps1 [-Filter <name>] [-Out <file.md>] [-RawOut <file.txt>]
#                              [-GodotPath <exe>] [-SkipImport]
# With -Filter and no -Out, nothing is written (the baseline keeps every benchmark).
# Godot is taken from -GodotPath, then $env:GODOT, then "godot" on PATH.
# Timings are wall-clock and host-dependent: run nothing else heavy meanwhile, and never
# gate CI on them. The full set takes about 15-25 min. A benchmark fails (exit 1 overall) when
# it exits non-zero or prints a SCRIPT ERROR; exit 3 in the report marks the latter.
[CmdletBinding()]
param(
    [string]$Filter = "",
    [string]$Out = "",
    [string]$RawOut = "",
    [string]$GodotPath = "",
    [switch]$SkipImport
)

# Godot writes warnings to stderr; "Continue" keeps 2>&1 from turning them into terminating errors.
$ErrorActionPreference = "Continue"
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$gameRoot = Join-Path $repoRoot "game"
$benchDir = Join-Path $gameRoot "scripts\tests"

if (-not $GodotPath) { $GodotPath = $env:GODOT }
if (-not $GodotPath) { $GodotPath = "godot" }
if (-not (Get-Command $GodotPath -ErrorAction SilentlyContinue)) {
    Write-Output "run_benches: Godot not found ('$GodotPath'). Set `$env:GODOT to the 4.7.2 console executable."
    exit 2
}
if (-not $Out -and -not $Filter) { $Out = Join-Path $repoRoot "docs\architecture\bench-baseline.md" }

if (-not $SkipImport) {
    Write-Output "=== Importing project (class cache) ==="
    & $GodotPath --headless --path $gameRoot --import 2>&1 | Out-Null
}

$benches = Get-ChildItem -Path $benchDir -Filter "bench_*.gd" |
    Where-Object { $_.Name -ne "bench_common.gd" } | Sort-Object Name
if ($Filter) { $benches = $benches | Where-Object { $_.Name -like "*$Filter*" } }
if (@($benches).Count -eq 0) { Write-Output "run_benches: no bench_*.gd matches '$Filter'"; exit 1 }

$commit = (& git -C $repoRoot rev-parse --short HEAD 2>$null | Out-String).Trim()
if (-not $commit) { $commit = "unknown" }
& git -C $repoRoot diff --quiet HEAD -- game tools 2>$null
$dirty = $LASTEXITCODE -ne 0
$started = Get-Date
# Other Godot processes (other worktrees, the game window) skew wall-clock numbers; the
# report records the most seen between benchmarks so a noisy baseline says so.
function Get-OtherGodotCount { @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -like "Godot*" }).Count }
$otherGodot = Get-OtherGodotCount

$results = @()
foreach ($bench in $benches) {
    Write-Output "=== Running $($bench.BaseName) ==="
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $output = & $GodotPath --headless --path $gameRoot --script "res://scripts/tests/$($bench.Name)" 2>&1 | ForEach-Object { "$_" }
    $exitCode = $LASTEXITCODE
    $sw.Stop()
    # A GDScript runtime error aborts only the current function, so a benchmark calling a
    # method that a refactor moved can still exit 0 with wrong numbers: count it as a failure.
    $scriptErrors = @($output | Where-Object { $_ -match 'SCRIPT ERROR' })
    if ($scriptErrors.Count -gt 0 -and $exitCode -eq 0) { $exitCode = 3 }
    $lines = @($output | Where-Object { $_ -match '^bench_' })
    $rows = @($output | Where-Object { $_.StartsWith("@row ") } | ForEach-Object { $_.Substring(5) | ConvertFrom-Json })
    $lines += ("{0}: wall={1:n0}s exit={2}" -f $bench.BaseName, $sw.Elapsed.TotalSeconds, $exitCode)
    if ($scriptErrors.Count -gt 0) {
        $lines += ("{0}: {1} SCRIPT ERROR line(s), first: {2}" -f $bench.BaseName, $scriptErrors.Count, $scriptErrors[0].Trim())
    }
    $lines | ForEach-Object { Write-Output $_ }
    if ($exitCode -ne 0) {
        # A failing benchmark keeps its error output, so the report says why.
        $output | Where-Object { $_ -match 'ERROR|Parse Error' } | Select-Object -First 10 | ForEach-Object { Write-Output "  $_" }
    }
    $otherGodot = [Math]::Max($otherGodot, (Get-OtherGodotCount))
    $results += [pscustomobject]@{
        Name = $bench.BaseName; Lines = $lines; Rows = $rows; Exit = $exitCode; Seconds = $sw.Elapsed.TotalSeconds
    }
}

function Format-Cell([object]$value) {
    if ($null -eq $value) { return "" }
    $text = "$value"
    if ($value -is [bool]) { $text = $text.ToLower() }
    return $text.Replace("|", "\|")
}

# One Markdown table: the union of the rows' columns in first-seen order, "case" first.
function ConvertTo-MarkdownTable([object[]]$tableRows) {
    $columns = New-Object System.Collections.Generic.List[string]
    foreach ($r in $tableRows) {
        foreach ($p in $r.values.PSObject.Properties) {
            if (-not $columns.Contains($p.Name)) { $columns.Add($p.Name) }
        }
    }
    $md = @()
    $md += "| case | " + (($columns | ForEach-Object { Format-Cell $_ }) -join " | ") + " |"
    $md += "| --- | " + (($columns | ForEach-Object { "---:" }) -join " | ") + " |"
    foreach ($r in $tableRows) {
        $cells = foreach ($c in $columns) { Format-Cell $r.values.$c }
        $md += "| " + (Format-Cell $r.case) + " | " + ($cells -join " | ") + " |"
    }
    return $md
}

$allLines = @($results | ForEach-Object { $_.Lines })
if ($RawOut) { $allLines | Set-Content -Path $RawOut -Encoding utf8 }

if ($Out) {
    # Host fields come from the first benchmark header line ("<bench>: commit=... godot=... os=... cpu=... threads=N").
    $hostLine = $allLines | Where-Object { $_ -match ': commit=\S+ godot=' } | Select-Object -First 1
    $hostText = "unknown"
    if ($hostLine -and $hostLine -match 'godot=(.+?) os=(\S+) cpu=(.+) threads=(\d+)$') {
        $hostText = "{0}, {1} threads, {2}, Godot {3} headless" -f $Matches[3], $Matches[4], $Matches[2], $Matches[1]
    }
    $treeText = if ($dirty) { "``$commit`` plus uncommitted changes under ``game/`` or ``tools/``" } else { "``$commit``" }
    $md = @()
    $md += "# Benchmark baseline"
    $md += ""
    $md += "> Generated by ``tools\run_benches.ps1``; do not edit by hand. Regenerate on the same"
    $md += "> host before quoting before/after numbers, and quote the lines of this file that the change"
    $md += "> moves. Timings are wall-clock and host-dependent; they are evidence, not a CI gate."
    $md += ""
    $md += "- **Commit:** $treeText"
    $md += "- **Host:** $hostText"
    $md += ("- **Run:** {0:yyyy-MM-dd HH:mm}, {1:n0} min in total" -f $started, ((Get-Date) - $started).TotalMinutes)
    $md += ("- **Other Godot processes on the host:** up to {0} (sampled before and between benchmarks; 0 is a quiet run)" -f $otherGodot)
    $md += ""
    $md += "The benchmarks and what each one measures are described in the header comment of each"
    $md += "``game/scripts/tests/bench_*.gd`` and in ``docs/architecture/foundation-audit.md``."
    foreach ($r in $results) {
        $md += ""
        $md += "## $($r.Name)"
        $md += ""
        $md += ("Wall time {0:n0} s, exit code {1}." -f $r.Seconds, $r.Exit)
        # Tables in the order the benchmark first printed them.
        $tableNames = New-Object System.Collections.Generic.List[string]
        foreach ($row in $r.Rows) { if (-not $tableNames.Contains($row.table)) { $tableNames.Add($row.table) } }
        foreach ($name in $tableNames) {
            $md += ""
            $md += "### $name"
            $md += ""
            $md += ConvertTo-MarkdownTable @($r.Rows | Where-Object { $_.table -eq $name })
        }
        $md += ""
        $md += "<details><summary>Raw lines</summary>"
        $md += ""
        $md += '```text'
        $md += $r.Lines
        $md += '```'
        $md += ""
        $md += "</details>"
    }
    [System.IO.File]::WriteAllText($Out, (($md -join "`n") + "`n"), (New-Object System.Text.UTF8Encoding($false)))
    Write-Output "run_benches: wrote $Out"
}

$failed = @($results | Where-Object { $_.Exit -ne 0 })
if ($failed.Count -gt 0) {
    Write-Output ("run_benches: {0} of {1} benchmark(s) exited non-zero: {2}" -f $failed.Count, $results.Count, (($failed | ForEach-Object { $_.Name }) -join ", "))
    exit 1
}
Write-Output ("run_benches: all {0} benchmark(s) exit 0" -f $results.Count)
exit 0
