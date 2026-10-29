extends Node

## Debug viewer entry point: composes the scene around one WorldState, prints
## its state hash, and drives it purely through explicit ticks. The logic lives
## in the scripts/viewer/ modules preloaded below; this node owns the references
## and passes them in on every call, so a test can swap any of them first.

const WorldStateType = preload("res://scripts/core/world_state.gd")
const DebugScenarioType = preload("res://scripts/viewer/debug_scenario.gd")
const TickDriverType = preload("res://scripts/viewer/tick_driver.gd")
const TextTableType = preload("res://scripts/viewer/text_table.gd")
const MapViewportType = preload("res://scripts/viewer/map_viewport.gd")
const MapViewType = preload("res://scripts/viewer/map_view.gd")
const AutosaveTriggerType = preload("res://scripts/viewer/autosave_trigger.gd")
const SaveManagerType = preload("res://scripts/core/persistence/save_manager.gd")
const ContentRegistryType = preload("res://scripts/core/content/content_registry.gd")
const ScenarioBuilderType = preload("res://scripts/core/world/scenario_builder.gd")
const NewGameDialogType = preload("res://scripts/viewer/new_game_dialog.gd")
const OrderInputType = preload("res://scripts/viewer/order_input.gd")
const SaveWiringType = preload("res://scripts/viewer/save_wiring.gd")
const StatusTextType = preload("res://scripts/viewer/status_text.gd")
const ControlBarType = preload("res://scripts/viewer/control_bar.gd")
const InfoPanelType = preload("res://scripts/viewer/info_panel.gd")
const CommandRecorderType = preload("res://scripts/viewer/command_recorder.gd")

const Tool = OrderInputType.Tool
const DEFAULT_BOOT_SEED := 20260915
## Content pack roots applied, in this order, on top of res://content/ (A13,
## ADR 010 amendment); none ship yet, so the session runs the base bundle.
const CONTENT_PACK_ROOTS: Array[String] = []

## The one ContentRegistry of this session, built on first use from the base
## bundle plus CONTENT_PACK_ROOTS and shared by every world boot builds.
static var _session_content: ContentRegistryType

var world: WorldStateType
var tick_driver: TickDriverType
var save_manager: SaveManagerType
var autosave_trigger: AutosaveTriggerType
## F9 records the live session for tools/replay.ps1 (A11, docs/architecture/replay.md).
var command_recorder := CommandRecorderType.new()
var last_recording_path: String = ""

var _text_table: TextTableType
var _orders := OrderInputType.new()
var _map_view: MapViewType
var _map_viewport: Control
var _controls: ControlBarType
var _ui_scroll: InfoPanelType
var _rejected_tiles_label: Label
var _need_alerts_label: Label
var _room_label: Label
var _new_game_confirm: NewGameDialogType
var _startup_resume_message: String = ""
## Game-session marker for every save (save_manager.gd's header): 0 for the
## _init() world, adopted from a loaded save, bumped to a strictly new value
## for a New Game / Debug Scenario so its saves outrank an older game's.
var _current_epoch: int = 0
# Read-only views onto the composed parts, under the names the viewer tests use.
var _selected_tool: int:
	get: return _orders.selected_tool
var _tool_buttons: Dictionary:
	get: return _orders.tool_buttons
var _wall_kind_buttons: Dictionary:
	get: return _orders.wall_kind_buttons
var _seed_input: LineEdit:
	get: return _controls.seed_input if _controls != null else null
var _active_seed_label: Label:
	get: return _controls.active_seed_label if _controls != null else null
var _ui_content: VBoxContainer:
	get: return _ui_scroll.content if _ui_scroll != null else null
var _status_label: Label:
	get: return _ui_scroll.status_label if _ui_scroll != null else null
var _work_table_panel: Control:
	get: return _ui_scroll.work_table_panel if _ui_scroll != null else null

## Built in _init(), not _ready(): headless tests (test_viewer_hash.gd,
## test_order_input.gd) instantiate this scene and call _commit_rectangle()
## and read _rejected_tiles_label.text before the tree has run a frame.
func _init() -> void:
	world = build_default_world()
	_text_table = TextTableType.new(TextTableType.requested_locale())
	_rejected_tiles_label = Label.new()
	_need_alerts_label = Label.new()
	_room_label = Label.new()

## The default boot world is a real New Game: scenarios.json's "new_game" entry (A16,
## ADR 053) at mapgen.json's default size with incidents enabled (only the live viewer
## wants spawn_incident reachable), never the debug scenario. Pure, so
## test_viewer_hash.gd can call it directly. content defaults to the session registry; a
## test passes its own to build on a pack. tick_rate null keeps the scenario's own rate.
static func build_default_world(seed_value: int = DEFAULT_BOOT_SEED, tick_rate: Variant = null,
		content: ContentRegistryType = null, scenario_id: String = ScenarioBuilderType.NEW_GAME_SCENARIO_ID) -> WorldStateType:
	if content == null:
		content = session_content()
	var options := {"seed": seed_value}
	if tick_rate != null:
		options["tick_rate"] = int(tick_rate)
	return ScenarioBuilderType.build(content, scenario_id, options)

static func session_content() -> ContentRegistryType:
	if _session_content == null:
		_session_content = ContentRegistryType.new(ContentRegistryType.DEFAULT_CONTENT_DIR,
			ContentRegistryType.DEFAULT_SCHEMA_DIR, CONTENT_PACK_ROOTS)
	return _session_content

func _ready() -> void:
	tick_driver = TickDriverType.new(world)
	add_child(tick_driver)
	save_manager = SaveManagerType.new(SaveManagerType.DEFAULT_SAVE_DIR, session_content())
	autosave_trigger = AutosaveTriggerType.new(world, save_manager)
	add_child(autosave_trigger)
	# Wired unconditionally, not only when the UI builds below: autosave must
	# keep firing on tick boundaries in a headless run too.
	tick_driver.ticked.connect(_on_ticked)
	autosave_trigger.autosaved.connect(_on_autosaved)
	_restore_from_save()
	print("Deepholm debug viewer boot hash: %d" % world.state_hash())
	if DisplayServer.get_name() == "headless":
		return
	_build_ui()

## Resumes the persisted colony on startup through the Load button's path; with
## no valid save the _init() world stays and the status reads "last saved: never".
func _restore_from_save() -> void:
	var result := SaveWiringType.load_best(save_manager)
	if not result.get("ok", false):
		return
	_adopt_loaded(result)
	_startup_resume_message = SaveWiringType.resume_message(_text_table, result)

## Fixed screen regions: wrapping toolbar, clipped map, independently
## scrollable information/work panel. No camera transform reaches the HUD.
func _build_ui() -> void:
	var layout := VBoxContainer.new()
	layout.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(layout)
	_controls = ControlBarType.new()
	layout.add_child(_controls)
	_controls.build(_text_table, _orders, _make_incident_buttons(), {
		"pause": func(): tick_driver.pause(), "step": func(): tick_driver.step_once(),
		"speed": func(speed: int): tick_driver.set_speed(speed), "save": _on_save_pressed, "load": _on_load_pressed,
		"center": func(): _map_viewport.center_colonists(), "select_tool": _select_tool,
		"toggle_art": func(): _map_view.toggle_art_enabled(), "new_game": _on_new_game_pressed,
		"debug_scenario": _on_debug_scenario_pressed, "select_wall_kind": func(kind: String): _orders.select_wall_kind(_map_view, kind),
		"rotate_build": func(): _orders.rotate_build(world, _map_view)})
	var hint := Label.new()
	hint.text = _text_table.get_string("controls.map_hint")
	layout.add_child(hint)
	var body := HBoxContainer.new()
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	layout.add_child(body)
	_map_viewport = MapViewportType.new()
	_map_viewport.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.add_child(_map_viewport)
	_map_view = MapViewType.new()
	_map_view.set_world(world)
	_map_view.set_tick_driver(tick_driver)
	_map_view.rectangle_committed.connect(_commit_rectangle)
	_map_view.zone_add_committed.connect(func(result: Dictionary): _show_map_result(StatusTextType.zone_result_text(_text_table, result)))
	_map_view.build_committed.connect(func(result: Dictionary): _show_map_result(StatusTextType.build_result_text(_text_table, result)))
	_map_view.tool_left.connect(func(): _select_tool(-1))
	_map_view.preview_validity = _preview_validity
	_map_viewport.attach(_map_view)
	_ui_scroll = InfoPanelType.new()
	body.add_child(_ui_scroll)
	_ui_scroll.build(world, _text_table, [_rejected_tiles_label, _need_alerts_label, _room_label])
	if _startup_resume_message != "":
		_status_label.text = _startup_resume_message
	else:
		_status_label.text = SaveWiringType.last_saved_text(_text_table, save_manager)
	_update_need_alerts_label()
	_update_active_seed_label()
	_new_game_confirm = NewGameDialogType.new(_text_table)
	_new_game_confirm.set_scenarios(session_content().list("scenarios"))
	_new_game_confirm.confirmed.connect(_on_new_game_confirmed)
	add_child(_new_game_confirm)
	_map_viewport.call_deferred("center_colonists")

## Hover colouring: OrderInput.preview_validity(), a read-only WorldState.preview() dry run.
func _preview_validity(tiles: Array[Vector2i]) -> Array[bool]:
	return _orders.preview_validity(world, world.preview, _map_view, tiles)

func _command_for_tile(tool: int, tile: Vector2i) -> Dictionary:
	return OrderInputType.command_for_tile(world, _map_view, tool, tile)

func _wall_command(tiles: Array[Vector2i]) -> Dictionary:
	return _orders.wall_command(world, tiles)

## Applies the selected tool over the rectangle (OrderInput.commit_rectangle())
## and returns every rejected tile so the caller (and tests) can inspect the
## reason without depending on UI.
func _commit_rectangle(tiles: Array[Vector2i]) -> Array[Dictionary]:
	var rejected := _orders.commit_rectangle(world, _map_view, tiles)
	_refresh()
	if _rejected_tiles_label != null:
		_rejected_tiles_label.text = StatusTextType.rejected_tiles_text(_text_table, rejected)
	return rejected

func _select_tool(tool: int) -> void:
	_orders.select_tool(world, _map_view, tool)

## Zone and build clicks commit through the map view's own command path;
## this shows (or clears) the rejection text that path produced.
func _show_map_result(text: String) -> void:
	_refresh_room_label()
	if _rejected_tiles_label != null:
		_rejected_tiles_label.text = text

func _on_ticked() -> void:
	command_recorder.observe_tick(world) # first: the checkpoint is the state right after tick()
	autosave_trigger.check(world.get_tick())
	_refresh()

func _refresh() -> void:
	if _map_view != null:
		_map_view.refresh()
	if _ui_scroll != null:
		_ui_scroll.refresh()
	_update_need_alerts_label()
	_refresh_room_label()

func _update_need_alerts_label() -> void:
	if _need_alerts_label != null:
		_need_alerts_label.text = StatusTextType.need_alerts_text(world, _text_table)

func _refresh_room_label() -> void:
	if _room_label != null:
		_room_label.text = StatusTextType.room_text(world, _text_table, _orders.has_inspected_tile, _orders.inspected_tile)

## One debug Spawn button per content incident (ControlBar.make_incident_buttons()).
func _make_incident_buttons() -> Array[Button]:
	if _text_table == null:
		_text_table = TextTableType.new(TextTableType.requested_locale())
	return ControlBarType.make_incident_buttons(world, _text_table, spawn_incident)

## Returns WorldState.apply()'s own result so a caller can inspect it.
func spawn_incident(incident_id: String) -> Dictionary:
	var result: Dictionary = world.apply({
		"actor": "player", "command_id": "viewer_spawn_incident_%s_%d" % [incident_id, world.get_tick()],
		"tick": world.get_tick(), "type": "spawn_incident", "payload": {"id": incident_id},
	})
	_set_status(StatusTextType.spawn_incident_text(_text_table, StatusTextType.incident_display_name(_text_table, incident_id), result))
	return result

func _on_save_pressed() -> void:
	_on_autosaved(SaveWiringType.save_manual(save_manager, autosave_trigger, world, _current_epoch))

func _on_load_pressed() -> void:
	var result := SaveWiringType.load_best(save_manager)
	if not result.get("ok", false):
		_set_status(_text_table.get_string("status.load_failed"))
		return
	_adopt_loaded(result)
	_set_status(SaveWiringType.resume_message(_text_table, result))

## decode() builds with incidents disabled; the live viewer re-enables them on
## every restored world, or a resumed colony loses its incidents and Spawn buttons.
func _adopt_loaded(result: Dictionary) -> void:
	_current_epoch = int(result.get("epoch", 0))
	var loaded: WorldStateType = result["world"]
	loaded.enable_incidents()
	_replace_world(loaded)

## Every save result, manual or autosave, is shown; see SaveWiring.save_result_text().
func _on_autosaved(result: Dictionary) -> void:
	_set_status(SaveWiringType.save_result_text(_text_table, save_manager, result))

func _on_new_game_pressed() -> void:
	var refusal := _new_game_confirm.ask(_seed_input)
	if refusal != "":
		_set_status(refusal)

func _on_new_game_confirmed() -> void:
	_start_new_game(_new_game_confirm.pending_seed, _new_game_confirm.pending_scenario_id)

## Explicit opt-in to DebugScenario's seeded diagnostic world; never the default.
func _on_debug_scenario_pressed() -> void:
	var debug_world := DebugScenarioType.build(null, null, true, session_content())
	_swap_in_unsaved_world(debug_world, _text_table.format("status.debug_scenario_started", [debug_world.get_seed()]))

func _start_new_game(seed_value: int, scenario_id: String = ScenarioBuilderType.NEW_GAME_SCENARIO_ID) -> void:
	var new_world := build_default_world(seed_value, null, null, scenario_id)
	_swap_in_unsaved_world(new_world, _text_table.format("status.new_game_started", [seed_value, new_world.get_map_width(), new_world.get_map_height()]))

## Swaps in a fresh colony like Load does, never touching the previous save.
## Mints a strictly new epoch, suspends autosave until an explicit Save (an
## unsaved new game must not rotate into the replaced game's autosave slots),
## and starts paused.
func _swap_in_unsaved_world(new_world: WorldStateType, status: String) -> void:
	_current_epoch = SaveWiringType.next_epoch(_current_epoch, save_manager)
	_replace_world(new_world)
	autosave_trigger.set_enabled(false)
	tick_driver.pause()
	_set_status(status)

func _set_status(text: String) -> void:
	if _status_label != null:
		_status_label.text = text

func _unhandled_key_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_F9:
		_toggle_recording()
		get_viewport().set_input_as_handled()

## F9: starts recording the running world from its current tick, or stops and
## writes the recording to user://replays/.
func _toggle_recording() -> void:
	if command_recorder.is_recording():
		_stop_recording()
		return
	command_recorder.start(world)
	_set_status(_text_table.format("status.recording_started", [world.get_tick()]))

## A recording never spans two worlds: _replace_world() stops and saves it first.
func _stop_recording() -> void:
	if not command_recorder.is_recording():
		return
	var recording := command_recorder.stop()
	var written := CommandRecorderType.write_file(recording, CommandRecorderType.session_path(recording))
	var text: String
	if written.get("ok", false):
		last_recording_path = written["path"]
		text = _text_table.format("status.recording_saved", [recording.start_tick, recording.end_tick, ProjectSettings.globalize_path(last_recording_path)])
	else:
		text = _text_table.format("status.recording_not_saved", [_text_table.format_named("recording.error.%s" % written["code"], written)])
	print(text)
	_set_status(text)

## Repoints presentation and the tick/autosave drivers at a newly loaded or
## created WorldState; mutates no simulation state.
func _replace_world(new_world: WorldStateType) -> void:
	_stop_recording()
	world = new_world
	tick_driver.world = new_world
	autosave_trigger.attach(new_world, save_manager, _current_epoch)
	if _map_view != null:
		_map_view.set_world(new_world)
		# Reapplies camera bounds, or a smaller new world leaves the view blank.
		_map_viewport.center_colonists()
	if _ui_scroll != null:
		_ui_scroll.set_world(new_world)
	_update_need_alerts_label()
	_update_active_seed_label()
	_refresh_room_label()

func _update_active_seed_label() -> void:
	if _active_seed_label != null:
		_active_seed_label.text = _text_table.format("controls.active_seed_label", [world.get_seed()])
