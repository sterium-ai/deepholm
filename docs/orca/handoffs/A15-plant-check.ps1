# A15 evidence: plants (1) an English literal in the viewer and (2) a missing en.json key for a
# core rejection detail, runs the matching test on each, and restores both files afterwards
# (also on Ctrl+C).
# Expected: clean runs exit 0; planted literal -> test_viewer_text_lint exit 1 naming
# colonist_panel.gd "Accept"; dropped key -> test_text_pseudo_locale exit 1 naming
# 'rejection.trader_departed'; both files byte-identical at the end.
# Usage: docs\orca\handoffs\A15-plant-check.ps1   (Godot from $env:GODOT; run tools\run_tests.ps1 or --import first)
$ErrorActionPreference = "Continue"
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..\..")).Path
$gameRoot = Join-Path $repoRoot "game"
$panel = Join-Path $gameRoot "scripts\viewer\colonist_panel.gd"
$text = Join-Path $gameRoot "data\text\en.json"
$originals = @{ $panel = [System.IO.File]::ReadAllBytes($panel); $text = [System.IO.File]::ReadAllBytes($text) }

function Invoke-Test([string]$name) {
    $out = & $env:GODOT --headless --path $gameRoot --script "res://scripts/tests/$name.gd" 2>&1 | ForEach-Object { "$_" }
    $code = $LASTEXITCODE
    $detail = ($out | Where-Object { $_ -match "PASS|ERROR: |colonist_panel.gd:" -and $_ -notmatch "resources still in use" } | Select-Object -First 2) -join " | "
    return "exit $code  $detail"
}

function Restore-All {
    foreach ($path in $originals.Keys) { [System.IO.File]::WriteAllBytes($path, $originals[$path]) }
}

try {
    Write-Output ("plant_check: {0,-34} {1}" -f "clean lint", (Invoke-Test "test_viewer_text_lint"))
    Write-Output ("plant_check: {0,-34} {1}" -f "clean pseudo locale", (Invoke-Test "test_text_pseudo_locale"))
    $source = [System.Text.Encoding]::UTF8.GetString($originals[$panel])
    $planted = $source.Replace('accept_button.text = _text_table.get_string("colonists.accept_trade")', 'accept_button.text = "Accept"')
    [System.IO.File]::WriteAllText($panel, $planted)
    Write-Output ("plant_check: {0,-34} {1}" -f "literal planted in viewer", (Invoke-Test "test_viewer_text_lint"))
    Restore-All
    $lines = [System.Text.Encoding]::UTF8.GetString($originals[$text]) -split "`n" | Where-Object { $_ -notmatch '"rejection\.trader_departed"' }
    [System.IO.File]::WriteAllText($text, ($lines -join "`n"))
    Write-Output ("plant_check: {0,-34} {1}" -f "rejection key dropped from en.json", (Invoke-Test "test_text_pseudo_locale"))
} finally {
    Restore-All
}
foreach ($path in $originals.Keys) {
    $same = [System.Linq.Enumerable]::SequenceEqual([byte[]]$originals[$path], [byte[]][System.IO.File]::ReadAllBytes($path))
    Write-Output ("plant_check: {0} restored byte-identical: {1}" -f (Split-Path $path -Leaf), $same)
}
