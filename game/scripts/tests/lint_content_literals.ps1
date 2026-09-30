[CmdletBinding()]
param()

# Fails if any game/scripts/core/**/*.gd file declares a tile-id string
# literal (rock/soil/floor/hazard/tree/water) as a constant's value, outside
# the registry that owns that data (content_registry.gd). world_state.gd's own
# TILE_ROCK/TILE_SOIL/TILE_FLOOR/TILE_HAZARD/TILE_TREE/TILE_WATER constants
# alias content_registry.gd's (ContentRegistryType.TILE_ROCK, etc.) rather than
# redeclaring the literals, so world_state.gd is not exempted here: any core
# file assigning one of these strings directly to a constant is exactly the
# duplication this lint exists to catch.

$tileKinds = @('rock', 'soil', 'floor', 'hazard', 'tree', 'water')
$literalPattern = '"(' + ($tileKinds -join '|') + ')"'
$constPattern = "const\s+\w+\s*(:=|:\s*\w+\s*=|=)\s*$literalPattern"

# Also fails on: a WORK_TICKS-shaped dictionary literal (a const
# dict keyed by at least three of dig/chop/forage/sleep) or a bare
# MOVE_TICKS_PER_TILE const, either of which would mean the move/work tick
# costs that live in content/jobs.json and content/tiles.json had crept
# back into a hard-coded GDScript literal outside the registry.
$workTicksKeys = @('dig', 'chop', 'forage', 'sleep')
$workTicksDictPattern = 'const\s+\w+\s*(:=|:\s*\w+\s*=|=)\s*\{'
$moveTicksConstPattern = 'const\s+\w*MOVE_TICKS_PER_TILE\w*\s*(:=|:\s*\w+\s*=|=)\s*\d+'

# Scans an already-split array of source lines and returns one formatted
# offender string per violation, prefixed with $relativePath. Shared between
# the real repo scan below and Test-LintDetectsKnownViolations's synthetic
# fixtures, so the fixture proves exactly the logic that runs on real files.
function Find-ContentLiteralOffenders {
    param(
        [string[]] $Lines,
        [string] $RelativePath
    )
    $found = @()
    $lineNumber = 0
    # A WORK_TICKS-shaped dict can span multiple lines (one key per line), so
    # the opening "const ... := {" line alone never carries 3+ of the
    # dig/chop/forage/sleep keys. Once an opening line is seen, buffer every
    # line through the matching closing brace (tracked by net '{'/'}' count)
    # and test the whole block's text for the key threshold, rather than
    # testing only the line the literal happens to open on.
    $inDict = $false
    $dictDepth = 0
    $dictStartLine = 0
    $dictBuffer = @()
    foreach ($line in $Lines) {
        $lineNumber++
        if ($line -match $constPattern) {
            $found += "{0}:{1}: {2}" -f $RelativePath, $lineNumber, $line.Trim()
        }
        if ($line -match $moveTicksConstPattern) {
            $found += "{0}:{1}: {2}" -f $RelativePath, $lineNumber, $line.Trim()
        }
        if (-not $inDict -and ($line -match $workTicksDictPattern)) {
            $inDict = $true
            $dictDepth = 0
            $dictStartLine = $lineNumber
            $dictBuffer = @()
        }
        if ($inDict) {
            $dictBuffer += $line
            $dictDepth += ([regex]::Matches($line, '\{')).Count
            $dictDepth -= ([regex]::Matches($line, '\}')).Count
            if ($dictDepth -le 0) {
                $blockText = $dictBuffer -join "`n"
                $workTicksKeyMatches = 0
                foreach ($key in $workTicksKeys) {
                    if ($blockText -match "`"$key`"") {
                        $workTicksKeyMatches++
                    }
                }
                if ($workTicksKeyMatches -ge 3) {
                    $found += "{0}:{1}: {2}" -f $RelativePath, $dictStartLine, $dictBuffer[0].Trim()
                }
                $inDict = $false
            }
        }
    }
    return $found
}

# Self-test: proves Find-ContentLiteralOffenders rejects a
# WORK_TICKS dict split across lines, one key per line, not just the
# single-line shape. Runs
# against synthetic text, never against a file under scripts/core/, and stops
# the whole lint with a clear message if the detector regresses rather than
# silently scanning the real tree with a broken rule.
function Test-LintDetectsKnownViolations {
    $multilineWorkTicks = @(
        'const WORK_TICKS := {',
        '    "dig": 30,',
        '    "chop": 40,',
        '    "forage": 25,',
        '    "sleep": 60,',
        '}'
    )
    $offenders = Find-ContentLiteralOffenders -Lines $multilineWorkTicks -RelativePath 'selftest/multiline_work_ticks.gd'
    if ($offenders.Count -eq 0) {
        Write-Error 'lint self-test failed: a multiline WORK_TICKS-shaped dictionary literal was not detected.'
        exit 1
    }

    $singleLineWorkTicks = @('const WORK_TICKS := {"dig": 30, "chop": 40, "forage": 25, "sleep": 60}')
    $offenders = Find-ContentLiteralOffenders -Lines $singleLineWorkTicks -RelativePath 'selftest/single_line_work_ticks.gd'
    if ($offenders.Count -eq 0) {
        Write-Error 'lint self-test failed: a single-line WORK_TICKS-shaped dictionary literal was not detected.'
        exit 1
    }

    $moveTicksConst = @('const MOVE_TICKS_PER_TILE := 4')
    $offenders = Find-ContentLiteralOffenders -Lines $moveTicksConst -RelativePath 'selftest/move_ticks.gd'
    if ($offenders.Count -eq 0) {
        Write-Error 'lint self-test failed: a bare MOVE_TICKS_PER_TILE constant was not detected.'
        exit 1
    }

    $tileConst = @('const TILE_ROCK := "rock"')
    $offenders = Find-ContentLiteralOffenders -Lines $tileConst -RelativePath 'selftest/tile_const.gd'
    if ($offenders.Count -eq 0) {
        Write-Error 'lint self-test failed: a tile-id string constant was not detected.'
        exit 1
    }

    $unrelatedDict = @(
        'const LABOUR_KINDS := {',
        '    "mine": 1,',
        '    "chop": 2,',
        '}'
    )
    $offenders = Find-ContentLiteralOffenders -Lines $unrelatedDict -RelativePath 'selftest/unrelated_dict.gd'
    if ($offenders.Count -ne 0) {
        Write-Error 'lint self-test failed: a dict with only one WORK_TICKS-shaped key ("chop") was flagged as a false positive.'
        exit 1
    }
}

Test-LintDetectsKnownViolations

$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$coreDir = Join-Path $root 'scripts\core'
$excludedNames = @('content_registry.gd')

$offenders = @()
Get-ChildItem -Path $coreDir -Filter '*.gd' -Recurse | ForEach-Object {
    if ($excludedNames -contains $_.Name) {
        return
    }
    $sourceFile = $_
    $relativePath = $sourceFile.FullName.Substring($root.Length + 1)
    $lines = Get-Content -LiteralPath $sourceFile.FullName
    $offenders += Find-ContentLiteralOffenders -Lines $lines -RelativePath $relativePath
}

if ($offenders.Count -gt 0) {
    Write-Error 'Content literal(s) hardcoded outside the registry:'
    $offenders | ForEach-Object { Write-Error $_ }
    exit 1
}

Write-Output 'lint_content_literals: PASS (no tile-id/work-ticks/move-ticks literal found outside the registry)'
exit 0
