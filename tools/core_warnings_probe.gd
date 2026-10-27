extends SceneTree

## Compiles every script under res://scripts/core so the GDScript analyzer reports its
## warnings. Godot prints them only while a debugger is attached, so run it with -d
## (the local stdout debugger); tools/check_core_warnings.ps1 does that and counts them.
##   godot --headless -d --path game --script <abs path to this file>

const CORE_ROOT := "res://scripts/core"

## Untyped on purpose: check_core_warnings.ps1 requires its warning, which proves warnings are
## being reported (a run that prints none would otherwise count as zero).
var _warning_canary = 0

func _init() -> void:
	var paths: Array[String] = []
	_collect(CORE_ROOT, paths)
	paths.sort()
	var failed: Array[String] = []
	for path in paths:
		# load() hands back the resource even when it fails to compile; can_instantiate() is
		# false then.
		var script: Script = load(path)
		if script == null or not script.can_instantiate():
			failed.append(path)
	if not failed.is_empty():
		print("core_warnings_probe: failed to load %s" % ", ".join(failed))
		quit(1)
		return
	print("core_warnings_probe: loaded %d script(s)" % paths.size())
	quit(0)

func _collect(dir_path: String, out: Array[String]) -> void:
	for file in DirAccess.get_files_at(dir_path):
		if file.ends_with(".gd"):
			out.append(dir_path.path_join(file))
	for sub in DirAccess.get_directories_at(dir_path):
		_collect(dir_path.path_join(sub), out)
