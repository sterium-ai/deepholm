extends SceneTree

## A11: the live viewer's F9 recording, end to end through the real triggers.
## A real F9 key event starts recording on boot.gd's world; commands reach it
## only through WorldState.apply() (boot's spawn_incident(), the DIG
## rectangle commit, a direct apply()), so the recorder hears them through
## command_observer, and the area order's in-tick expansion is not heard; ticks go through the TickDriver's step_once() and boot's
## ticked handler. A second F9 writes the file, which replays OK. A world swap
## (New Game) while recording stops and saves the recording first, and leaves
## no observer on the replaced world.

const Boot = preload("res://scripts/boot.gd")
const SaveManagerType = preload("res://scripts/core/persistence/save_manager.gd")
const CommandRecorderType = preload("res://scripts/viewer/command_recorder.gd")
const ReplayLogType = preload("res://scripts/core/world/replay_log.gd")
const WorldStateType = preload("res://scripts/core/world_state.gd")
const MapViewType = preload("res://scripts/viewer/map_view.gd")

const SAVE_DIR := "user://test-boot-command-recording-saves"
const TICKS := 25

var failures: Array[String] = []
var boot: Node
var _written: Array[String] = []

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	boot = Boot.new()
	root.add_child(boot)
	await process_frame
	boot.save_manager = SaveManagerType.new(SAVE_DIR)
	_check_f9_records_and_replays()
	_check_world_swap_stops_and_saves()
	for path in _written:
		DirAccess.remove_absolute(path)
	root.remove_child(boot)
	boot.free()
	if not failures.is_empty():
		for failure in failures:
			push_error(failure)
		quit(1)
		return
	print("test_boot_command_recording: PASS")
	quit()

func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)

func _press_f9() -> void:
	var event := InputEventKey.new()
	event.keycode = KEY_F9
	event.pressed = true
	boot._unhandled_key_input(event)

func _check_f9_records_and_replays() -> void:
	var world: WorldStateType = boot.world
	_press_f9()
	_expect(boot.command_recorder.is_recording(), "F9 must start recording")
	_expect(world.command_observer.is_valid(), "recording must set the world's command observer")
	var start_tick := world.get_tick()
	boot.spawn_incident("trader_visit")
	var clearing := world.get_spawn_clearing()
	var corner := Vector2i(int(clearing["x"]), int(clearing["y"]))
	var tiles: Array[Vector2i] = MapViewType.tiles_in_rectangle(corner, corner + Vector2i(1, 1))
	# DIG over a 2x2 rectangle is one area_order whose per-tile expansion runs
	# inside tick(): only the area_order itself may be recorded, or the replay
	# would apply each expanded tile twice.
	boot._orders.selected_tool = Boot.Tool.DIG
	boot._commit_rectangle(tiles)
	var area_orders := 0
	world.apply({"actor": "player", "command_id": "boot_rec_noop", "tick": world.get_tick(), "type": "noop", "payload": {}})
	for i in TICKS:
		boot.tick_driver.step_once()
		if i == 12:
			world.apply({"actor": "player", "command_id": "boot_rec_mid", "tick": world.get_tick(), "type": "spawn_incident", "payload": {"id": "wildlife_wander"}})
	_press_f9()
	_expect(not boot.command_recorder.is_recording(), "a second F9 must stop recording")
	_expect(not world.command_observer.is_valid(), "stopping must clear the world's command observer")
	var path: String = boot.last_recording_path
	_expect(path.begins_with(CommandRecorderType.REPLAY_DIR) and FileAccess.file_exists(path), "F9 must write the recording under %s, got '%s'" % [CommandRecorderType.REPLAY_DIR, path])
	if not FileAccess.file_exists(path):
		return
	_written.append(path)
	var read := CommandRecorderType.read_file(path)
	_expect(read.get("ok", false), "the recorded file must read back: %s" % [read])
	if not read.get("ok", false):
		return
	var recording: ReplayLogType = read["log"]
	_expect(recording.start_tick == start_tick and recording.end_tick == start_tick + TICKS,
		"recording must span %d..%d, got %d..%d" % [start_tick, start_tick + TICKS, recording.start_tick, recording.end_tick])
	var ids := {}
	for entry in recording.commands:
		ids[String(entry["command"]["command_id"])] = true
		if String(entry["command"]["type"]) == "area_order":
			area_orders += 1
		_expect(String(entry["command"]["type"]) != "dig", "an area order's expanded per-tile dig must not be recorded")
	_expect(area_orders == 1, "the DIG rectangle must be recorded as one area_order, got %d" % area_orders)
	_expect(ids.has("boot_rec_noop") and ids.has("boot_rec_mid"), "commands applied on boot's world must be recorded: %s" % [ids.keys()])
	_expect(recording.commands.size() >= 4, "spawn_incident, the order rectangle and the direct commands must all be recorded, got %d" % recording.commands.size())
	_expect(recording.checkpoints.size() == TICKS / ReplayLogType.DEFAULT_CHECKPOINT_INTERVAL + 1,
		"expected %d checkpoints from boot's ticked handler, got %d" % [TICKS / ReplayLogType.DEFAULT_CHECKPOINT_INTERVAL + 1, recording.checkpoints.size()])
	var result := recording.replay()
	_expect(result.get("ok", false), "the live-viewer recording must replay: %s" % [result])

func _check_world_swap_stops_and_saves() -> void:
	var old_world: WorldStateType = boot.world
	boot.last_recording_path = ""
	_press_f9()
	boot.tick_driver.step_once()
	boot._start_new_game(7)
	_expect(not boot.command_recorder.is_recording(), "a world swap must stop the recording")
	_expect(not old_world.command_observer.is_valid(), "the replaced world must keep no command observer")
	_expect(not boot.world.command_observer.is_valid(), "the new world must not inherit an observer")
	var path: String = boot.last_recording_path
	_expect(FileAccess.file_exists(path), "a world swap must save the recording, got '%s'" % path)
	if FileAccess.file_exists(path):
		_written.append(path)
