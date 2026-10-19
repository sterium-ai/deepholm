# Prints total / code / comment line counts for every .gd file under game/scripts/core
# (and boot.gd), largest first, plus the longest function per file. Quote its output in
# refactor handoff reports.
# Usage: tools\measure_core.ps1 [-Top 30] [-All]
[CmdletBinding()]
param([int]$Top = 30, [switch]$All)

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$files = Get-ChildItem -Path (Join-Path $repoRoot "game\scripts\core") -Recurse -Filter "*.gd"
$files += Get-Item (Join-Path $repoRoot "game\scripts\boot.gd")

$rows = foreach ($f in $files) {
    $lines = Get-Content -LiteralPath $f.FullName
    $code = 0; $comment = 0; $blank = 0
    $longestFunc = ""; $longestLen = 0; $curFunc = ""; $curLen = 0
    foreach ($l in $lines) {
        $t = $l.Trim()
        if ($t -eq "") { $blank++ }
        elseif ($t.StartsWith("#")) { $comment++ }
        else {
            $code++
            if ($t -match '^(static\s+)?func\s+([A-Za-z_][A-Za-z0-9_]*)') {
                if ($curLen -gt $longestLen) { $longestLen = $curLen; $longestFunc = $curFunc }
                $curFunc = $Matches[2]; $curLen = 0
            }
            if ($curFunc) { $curLen++ }
        }
    }
    if ($curLen -gt $longestLen) { $longestLen = $curLen; $longestFunc = $curFunc }
    [pscustomobject]@{
        File = $f.FullName.Substring($repoRoot.Length + 1).Replace("\", "/")
        Total = $lines.Count; Code = $code; Comment = $comment
        LongestFunc = $longestFunc; FuncLines = $longestLen
    }
}

$rows = $rows | Sort-Object Total -Descending
if (-not $All) { $rows = $rows | Select-Object -First $Top }
$rows | Format-Table -AutoSize File, Total, Code, Comment, LongestFunc, FuncLines
$sum = $files | ForEach-Object { (Get-Content -LiteralPath $_.FullName).Count } | Measure-Object -Sum
Write-Output ("core total: {0} lines in {1} files" -f $sum.Sum, $files.Count)
