# Copies the Pixel Crawler sheets the game uses from the local pack into game/assets/pack/.
# The pack's terms forbid redistributing its files, so game/assets/pack/ is git-ignored and
# this script is the only way they reach a checkout. Without them the viewer falls back to
# the generated placeholders (game/scripts/viewer/pack_assets.gd).
# Usage: tools\sync_pack_assets.ps1 [-PackRoot <dir>] [-SkipImport]
# The pack root is taken from -PackRoot, then $env:DEEPHOLM_PACK, then C:\dev\assets\pixel-crawler.
# Exit code 1 when any file in the manifest is missing from the pack (nothing is half-copied
# silently: every missing file is listed).
[CmdletBinding()]
param(
    [string]$PackRoot = "",
    [switch]$SkipImport
)

$ErrorActionPreference = "Stop"
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$gameRoot = Join-Path $repoRoot "game"
$destRoot = Join-Path $gameRoot "assets\pack"
$manifestPath = Join-Path $gameRoot "data\sprite_frames\pack_manifest.json"

if (-not $PackRoot) { $PackRoot = $env:DEEPHOLM_PACK }
if (-not $PackRoot) { $PackRoot = "C:\dev\assets\pixel-crawler" }
if (-not (Test-Path -LiteralPath $PackRoot -PathType Container)) {
    Write-Output "sync_pack_assets: pack root not found: $PackRoot (set -PackRoot or `$env:DEEPHOLM_PACK)"
    exit 1
}

$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
$copied = 0; $unchanged = 0; $missing = @()
foreach ($relative in $manifest.files) {
    $source = Join-Path $PackRoot $relative
    $dest = Join-Path $destRoot $relative
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { $missing += $relative; continue }
    if ((Test-Path -LiteralPath $dest -PathType Leaf) -and
        (Get-FileHash -LiteralPath $source).Hash -eq (Get-FileHash -LiteralPath $dest).Hash) {
        $unchanged++; continue
    }
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dest) | Out-Null
    Copy-Item -LiteralPath $source -Destination $dest -Force
    $copied++
}

foreach ($relative in $missing) { Write-Output "sync_pack_assets: MISSING $relative" }

# Also re-import when a sheet has no .import yet (a previous import failed or was skipped).
$notImported = @($manifest.files | Where-Object {
    (Test-Path -LiteralPath (Join-Path $destRoot $_) -PathType Leaf) -and
    -not (Test-Path -LiteralPath ((Join-Path $destRoot $_) + ".import") -PathType Leaf) })
if (($copied -gt 0 -or $notImported.Count -gt 0) -and -not $SkipImport) {
    $godot = $env:GODOT
    if ($godot -and (Get-Command $godot -ErrorAction SilentlyContinue)) {
        # Imports the new sheets so load() finds them (the loader also reads raw PNGs, but
        # an exported build only carries imported textures). The output is kept in a log
        # next to the sheets (git-ignored) and a failed import fails the sync.
        $ErrorActionPreference = "Continue"
        $importLog = Join-Path $destRoot "import.log"
        & $godot --headless --path $gameRoot --import 2>&1 | ForEach-Object { "$_" } | Set-Content -LiteralPath $importLog -Encoding utf8
        $importExit = $LASTEXITCODE
        $ErrorActionPreference = "Stop"
        if ($importExit -ne 0) {
            Get-Content -LiteralPath $importLog -Tail 20 | ForEach-Object { Write-Output "  $_" }
            Write-Output "sync_pack_assets: Godot import FAILED (exit code $importExit); full output in $importLog"
            exit 1
        }
        Write-Output "sync_pack_assets: import OK (output in $importLog)"
    } else {
        Write-Output "sync_pack_assets: `$env:GODOT not set; run 'godot --headless --path game --import' before exporting"
    }
}

Write-Output ("sync_pack_assets: {0} copied, {1} unchanged, {2} missing of {3} in the manifest (from {4})" -f `
    $copied, $unchanged, $missing.Count, @($manifest.files).Count, $PackRoot)
if ($missing.Count -gt 0) { exit 1 }
exit 0
