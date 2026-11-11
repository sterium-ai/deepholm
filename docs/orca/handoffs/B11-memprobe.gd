extends SceneTree

## B11 evidence: where the default scenario's slow static-memory growth comes from.
## Headless, no frame pacing: runs --ticks= world ticks (default 3600 = 10 min at x1)
## twice on fresh default worlds, once core only (world.tick()) and once with the
## viewer refresh after every tick (boot._refresh(), what TickDriver does), and prints
## static MiB and object count every 600 ticks for each.
## Run, from the repo root:
##   & $env:GODOT --headless --path game --script "$PWD\docs\orca\handoffs\B11-memprobe.gd" -- --ticks=3600

const Boot = preload("res://scripts/boot.gd")

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
	var boot: Node = Boot.new()
	root.add_child(boot)
	boot.tick_driver.pause()
	if boot._map_view == null:
		boot._build_ui()
	boot._replace_world(Boot.build_default_world())
	await process_frame
	for i in ticks + 1:
		if i % 600 == 0:
			_row("core+refresh", i)
		boot.world.tick()
		boot._refresh()
	boot.queue_free()
	await process_frame
	print("B11-memprobe: done")
	quit(0)

func _row(mode: String, tick: int) -> void:
	print("%s,%d,%.2f,%d" % [mode, tick, Performance.get_monitor(Performance.MEMORY_STATIC) / 1048576.0,
		Performance.get_monitor(Performance.OBJECT_COUNT)])
