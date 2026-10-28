extends SceneTree

## A16 byte-identity probe for scenario-built worlds. For each case it builds the world through
## the entry points boot.gd uses (Boot.build_default_world() for a New Game,
## DebugScenario.build() for the debug scenario), writes the saved state (to_save_state(), the
## exact JSON a save would hold), the event log and state_hash() at tick 0, then ticks
## TRACE_TICKS times and appends state_hash() every 10 ticks plus the final saved state.
## Cases: three New Game seeds at mapgen.json's default size (the boot seed, 42, 7) and the
## debug scenario three ways (tests' default, the boot button's incidents-on build, and a
## non-canonical seed that skips the farm bootstrap). Runs unchanged on main and on A16.
## Lives outside game/ (not part of the suite):
##   godot --headless --path game --script <abs path to this file> -- <abs out dir>

const BootType = preload("res://scripts/boot.gd")
const DebugScenarioType = preload("res://scripts/viewer/debug_scenario.gd")

const TRACE_TICKS := 100

func _init() -> void:
	var args := OS.get_cmdline_user_args()
	if args.is_empty():
		push_error("usage: -- <out dir>")
		quit(2)
		return
	var out_dir := String(args[0])
	DirAccess.make_dir_recursive_absolute(out_dir)
	var cases := {
		"new_game_20260915": func() -> Variant: return BootType.build_default_world(),
		"new_game_42": func() -> Variant: return BootType.build_default_world(42, 10),
		"new_game_7": func() -> Variant: return BootType.build_default_world(7, 10),
		"debug_default": func() -> Variant: return DebugScenarioType.build(),
		"debug_button": func() -> Variant: return DebugScenarioType.build(20260915, 10, true),
		"debug_seed_1201": func() -> Variant: return DebugScenarioType.build(1201),
	}
	for case_name: String in cases.keys():
		var world: Variant = (cases[case_name] as Callable).call()
		var lines: Array[String] = []
		lines.append("hash@0 %d" % world.state_hash())
		lines.append("save@0 %s" % JSON.stringify(world.to_save_state(), "", true))
		lines.append("events@0 %s" % JSON.stringify(world.get_events(), "", true))
		for i in TRACE_TICKS:
			world.tick()
			if (i + 1) % 10 == 0:
				lines.append("hash@%d %d" % [i + 1, world.state_hash()])
		lines.append("save@%d %s" % [TRACE_TICKS, JSON.stringify(world.to_save_state(), "", true)])
		var file := FileAccess.open(out_dir.path_join("%s.txt" % case_name), FileAccess.WRITE)
		file.store_string("\n".join(lines) + "\n")
		file.close()
		print("%s: %s" % [case_name, lines[0]])
	quit()
