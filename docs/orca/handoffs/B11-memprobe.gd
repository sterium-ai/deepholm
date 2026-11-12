extends SceneTree

## B11 evidence: where the default scenario's slow static-memory growth comes from.
## Headless, no frame pacing: runs --ticks= world ticks (default 3600 = 10 min at x1)
## twice on fresh default worlds, once core only (world.tick()) and once with the
## whole viewer callback after every tick (tick_driver.ticked: recorder, autosave check,
## boot._refresh(), what TickDriver does), and prints static MiB and object count every
## 600 ticks for each. Saves are isolated as in B11-profile.gd: ProfileBoot gets
## PROFILE_SAVE_DIR before entering the tree and, inside _ready(), swaps its save
## manager to it instead of resuming, so user://saves is never read or written.
## Run, from the repo root:
##   & $env:GODOT --headless --path game --script "$PWD\docs\orca\handoffs\B11-memprobe.gd" -- --ticks=3600

const Boot = preload("res://scripts/boot.gd")
const SaveManagerType = preload("res://scripts/core/persistence/save_manager.gd")
const PROFILE_SAVE_DIR := "user://b11-memprobe-saves"

class ProfileBoot extends Boot:
	var save_dir := ""

	func _restore_from_save() -> void:
		save_manager = SaveManagerType.new(save_dir, session_content())
		autosave_trigger.attach(world, save_manager, _current_epoch)

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	var ticks := 3600
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--ticks="):
			ticks = int(arg.trim_prefix("--ticks="))
	print("mode,tick,static_mib,objects")
	var world: Variant = Boot.build_default_world()
	for i in ticks + 1:
		if i % 600 == 0:
			_row("core", i)
		world.tick()
	world = null
	DirAccess.make_dir_recursive_absolute(PROFILE_SAVE_DIR)
	for file in DirAccess.get_files_at(PROFILE_SAVE_DIR):
		DirAccess.remove_absolute(PROFILE_SAVE_DIR.path_join(file))
	var boot: Node = ProfileBoot.new()
	boot.save_dir = PROFILE_SAVE_DIR
	root.add_child(boot)
	assert(boot.autosave_trigger.save_manager == boot.save_manager)
	boot.tick_driver.pause()
	if boot._map_view == null:
		boot._build_ui()
	boot._replace_world(Boot.build_default_world())
	await process_frame
	for i in ticks + 1:
		if i % 600 == 0:
			_row("core+refresh", i)
		boot.world.tick()
		boot.tick_driver.ticked.emit()
	boot.queue_free()
	await process_frame
	print("B11-memprobe: done")
	quit(0)

func _row(mode: String, tick: int) -> void:
	print("%s,%d,%.2f,%d" % [mode, tick, Performance.get_monitor(Performance.MEMORY_STATIC) / 1048576.0,
		Performance.get_monitor(Performance.OBJECT_COUNT)])
