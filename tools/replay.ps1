# Replays a recorded session headless and checks its state_hash() checkpoints (A11).
# Usage: tools\replay.ps1 <replay.json> [-GodotPath <exe>] [-SkipImport]
# Exit 0: every checkpoint matches. 1: diverged (prints the first diverging tick). 2: cannot replay.
# Godot is taken from -GodotPath, then $env:GODOT, then "godot" on PATH.
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)][string]$Path,
    [string]$GodotPath = "",
    [switch]$SkipImport
)

$ErrorActionPreference = "Continue"
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$gameRoot = Join-Path $repoRoot "game"
# The SceneTree script Godot runs. It is kept here, not as a separate .gd, and written to a
# temporary folder for each run; it is not part of the suite. The replay itself is
# ReplayLog.replay() (game/scripts/core/world/replay_log.gd).
$replayScript = @'
extends SceneTree

## Written and run by tools/replay.ps1: prints one "replay:" line and exits 0 when every
## checkpoint matches, 1 on the first divergence, 2 when the file cannot be replayed.

const CommandRecorderType = preload("res://scripts/viewer/command_recorder.gd")
const ReplayLogType = preload("res://scripts/core/world/replay_log.gd")

func _init() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() != 1:
		print("replay: ERROR usage: tools/replay.ps1 <replay.json>")
		quit(2)
		return
	var path := args[0]
	var read := CommandRecorderType.read_file(path)
	if not read.get("ok", false):
		print("replay: ERROR %s: %s" % [read.get("code"), read.get("message")])
		quit(2)
		return
	var replay_log: ReplayLogType = read["log"]
	print("replay: %s: seed %d, content %s, ticks %d..%d, %d commands, %d checkpoints (every %d ticks)" % [
		path, replay_log.world_seed, replay_log.content_version, replay_log.start_tick, replay_log.end_tick,
		replay_log.commands.size(), replay_log.checkpoints.size(), replay_log.checkpoint_interval])
	var result := replay_log.replay()
	if result.get("ok", false):
		print("replay: OK %d ticks, %d checkpoints and the final hash match, %d commands re-applied" % [
			result["ticks"], result["checkpoints"], result["commands"]])
		quit(0)
		return
	if result.get("code") == "diverged":
		print("replay: DIVERGED at tick %d (%s; last matching checkpoint %d; expected %d, actual %d)" % [
			result["tick"], result["kind"], result["last_matching_tick"], result["expected"], result["actual"]])
		quit(1)
		return
	print("replay: ERROR %s: %s" % [result.get("code"), result.get("message")])
	quit(2)
'@

if (-not $GodotPath) { $GodotPath = $env:GODOT }
if (-not $GodotPath) { $GodotPath = "godot" }
if (-not (Get-Command $GodotPath -ErrorAction SilentlyContinue)) {
    Write-Output "replay: Godot not found ('$GodotPath'). Set `$env:GODOT to the 4.7.2 console executable."
    exit 2
}
if (-not (Test-Path -LiteralPath $Path)) {
    Write-Output "replay: no file at '$Path'"
    exit 2
}
$fullPath = (Resolve-Path -LiteralPath $Path).Path

if (-not $SkipImport) {
    & $GodotPath --headless --path $gameRoot --import 2>&1 | Out-Null
}

$tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("deepholm-replay-" + [System.Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tempDir | Out-Null
$script = Join-Path $tempDir "replay.gd"
[System.IO.File]::WriteAllText($script, $replayScript)
try {
    $output = & $GodotPath --headless --path $gameRoot --script $script -- $fullPath 2>&1 | ForEach-Object { "$_" }
    $exitCode = $LASTEXITCODE
} finally {
    Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
}
$lines = @($output | Where-Object { $_ -match '^replay: ' })
$lines | Write-Output
if ($lines.Count -eq 0) {
    $output | Where-Object { $_ -match '(SCRIPT )?ERROR' } | Write-Output
    Write-Output "replay: the replay script printed no result (exit $exitCode)"
    exit 2
}
exit $exitCode
