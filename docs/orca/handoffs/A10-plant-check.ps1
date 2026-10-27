# A10 evidence: plants (1) an untyped declaration and (2) a parse error in a core file, runs
# tools\check_core_warnings.ps1 on each, and restores the file afterwards (also on Ctrl+C).
# Expected: clean run exit 0, planted untyped exit 1 ("warnings rose: untyped_declaration,
# total"), planted parse error exit 1 ("probe failed"), and the file byte-identical at the end.
# Usage: docs\orca\handoffs\A10-plant-check.ps1   (Godot from $env:GODOT)
$ErrorActionPreference = "Continue"
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..\..")).Path
$check = Join-Path $repoRoot "tools\check_core_warnings.ps1"
$target = Join-Path $repoRoot "game\scripts\core\world\event_log.gd"
$original = [System.IO.File]::ReadAllBytes($target)
$plants = [ordered]@{
    "clean" = ""
    "untyped declaration" = "`nfunc _planted() -> void:`n`tvar planted = 1`n`tprint(planted)`n"
    "parse error" = "`nfunc _broken( -> void:`n"
}
try {
    foreach ($name in $plants.Keys) {
        [System.IO.File]::WriteAllBytes($target, $original)
        if ($plants[$name]) { [System.IO.File]::AppendAllText($target, $plants[$name]) }
        $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $check -SkipImport 2>&1 | ForEach-Object { "$_" }
        $code = $LASTEXITCODE
        $last = ($out | Where-Object { $_ -match '^check_core_warnings:' } | Select-Object -Last 1)
        Write-Output ("plant_check: {0,-20} exit {1}  {2}" -f $name, $code, $last)
    }
} finally {
    [System.IO.File]::WriteAllBytes($target, $original)
}
$same = [System.Linq.Enumerable]::SequenceEqual([byte[]]$original, [byte[]][System.IO.File]::ReadAllBytes($target))
Write-Output "plant_check: event_log.gd restored byte-identical: $same"
