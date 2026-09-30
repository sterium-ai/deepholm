extends Node

## Debug viewer entry point. Builds the seeded scenario, prints
## its state hash, and drives WorldState purely through explicit ticks. See
## scripts/viewer/ for the map, colonist panel, and tick-speed controls.

const WorldStateType = preload("res://scripts/core/world_state.gd")
const DebugScenarioType = preload("res://scripts/viewer/debug_scenario.gd")
const TickDriverType = preload("res://scripts/viewer/tick_driver.gd")
const TextTableType = preload("res://scripts/viewer/text_table.gd")
const MapViewportType = preload("res://scripts/viewer/map_viewport.gd")
const MapViewType = preload("res://scripts/viewer/map_view.gd")
const ColonistPanelType = preload("res://scripts/viewer/colonist_panel.gd")
const WorkTablePanelType = preload("res://scripts/viewer/work_table_panel.gd")
const AutosaveTriggerType = preload("res://scripts/viewer/autosave_trigger.gd")
const SaveManagerType = preload("res://scripts/core/persistence/save_manager.gd")
const StateCodecType = preload("res://scripts/core/persistence/state_codec.gd")
const WorldGeneratorType = preload("res://scripts/core/worldgen/world_generator.gd")
const ContentRegistryType = preload("res://scripts/core/content/content_registry.gd")

enum Tool { DIG, CHOP, FORAGE, CANCEL, WALL, REMOVE_OBJECT, ZONE, TILL, SOW, MINE, BUILD_DOOR, BUILD_BED, BUILD_WORKBENCH }

const TEXT_TABLE_PATH := "res://data/text/en.json"

var world: WorldStateType
var tick_driver: TickDriverType
var save_manager: SaveManagerType
var autosave_trigger: AutosaveTriggerType

var _text_table: TextTableType
var _map_view: MapViewType
var _colonist_panel: ColonistPanelType
var _work_table_panel: WorkTablePanelType
var _ui_scroll: ScrollContainer
var _ui_content: Control
var _controls: HFlowContainer
var _map_viewport: Control
var _tool_buttons: Dictionary = {}
var _status_label: Label
var _rejected_tiles_label: Label
var _need_alerts_label: Label
var _room_label: Label
var _seed_input: LineEdit
var _active_seed_label: Label
var _wall_kind := "wooden_wall"
var _wall_kind_buttons: Dictionary = {}
var _rotate_build_button: Button
var _new_game_confirm: ConfirmationDialog
var _pending_new_game_seed: int = 0
var _startup_resume_message: String = ""
## Game-session marker passed to every save_manual()/save_autosave() call
## (save_manager.gd's header comment): 0 for the
## scenario/fixture world built in _init() and for any ordinary continuing
## game, adopted from a loaded save's own "epoch" by _restore_from_save()/
## _on_load_pressed(), and bumped to a strictly new value by
## _start_new_game() so a fresh game's saves always outrank an older game's
## regardless of raw tick.
var _current_epoch: int = 0
var _selected_tool: int = -1
var _inspected_tile: Vector2i = Vector2i(-1, -1)
var _has_inspected_tile: bool = false

## The world, text table, and rejected-tiles label are built in _init(),
## not _ready(): a headless SceneTree script (test_viewer_hash.gd,
## test_order_input.gd) instantiates this scene and calls into it
## synchronously from its own _init(), before the tree has run a frame, so
## _ready() has not fired yet at that point. Building here makes them
## available the moment the node exists, in both the viewer and the tests --
## test_order_input.gd calls _commit_rectangle() directly and inspects
## _rejected_tiles_label.text without ever waiting on a frame.
func _init() -> void:
	world = build_default_world()
	_text_table = TextTableType.new(TEXT_TABLE_PATH)
	_rejected_tiles_label = Label.new()
	_need_alerts_label = Label.new()
	_room_label = Label.new()

## The default boot world is a real New Game, not the debug scenario:
## WorldGenerator's river/vegetation generator at mapgen.json's
## default_new_game_width/height, with real starting tools and incidents
## enabled (the live viewer is the one caller that wants spawn_incident
## reachable). DebugScenarioType's seeded dig-order queue and forced
## furniture remain reachable only explicitly: by a test calling
## DebugScenarioType.build() directly (test_debug_scenario_objects.gd,
## test_viewer_hash.gd), or from the running viewer via the
## "Debug Scenario" button (_on_debug_scenario_pressed()). A pure function (no
## scene/node access) so test_viewer_hash.gd can call it directly and compare
## its hash against the scene-built world.
const DEFAULT_BOOT_SEED := 20260915

static func build_default_world(seed_value: int = DEFAULT_BOOT_SEED, tick_rate: int = 10) -> WorldStateType:
	var mapgen: Dictionary = ContentRegistryType.new().document("mapgen")
	var size := WorldGeneratorType.default_new_game_size(mapgen)
	var world := WorldStateType.new(seed_value, tick_rate, size.x, size.y)
	world.enable_incidents()
	_spawn_starting_tools(world, mapgen)
	_spawn_starting_beds(world, mapgen)
	return world

func _ready() -> void:
	tick_driver = TickDriverType.new(world)
	add_child(tick_driver)

	save_manager = SaveManagerType.new()
	autosave_trigger = AutosaveTriggerType.new(world, save_manager)
	add_child(autosave_trigger)
	# Wired unconditionally, not only when the UI builds below: autosave
	# must keep firing on tick boundaries in a headless run too, not only
	# while the debug viewer's controls are visible.
	tick_driver.ticked.connect(_on_ticked)
	autosave_trigger.autosaved.connect(_on_autosaved)

	_restore_from_save()

	print("Deepholm debug viewer boot hash: %d" % world.state_hash())

	if DisplayServer.get_name() == "headless":
		return

	_build_ui()

## Resumes the persisted colony on startup: runs the same
## load_best()-decode-replace path the Load button uses, once, so reloading
## the web tab after an autosave picks the saved colony back up instead of
## starting a fresh world every time. Reuses _replace_world() -- the
## same helper the Load button calls -- so tick_driver, autosave_trigger,
## and (once built) the map/colonist views all repoint at the restored
## world identically to a manual Load. When load_best() finds nothing
## valid, the fresh world built in _init() is left untouched and no
## message is recorded; _build_ui() falls back to the normal
## "last saved: never" status in that case.
func _restore_from_save() -> void:
	var result: Dictionary = save_manager.load_best()
	if not result.get("ok", false):
		return
	_current_epoch = int(result.get("epoch", 0))
	var new_world: WorldStateType = StateCodecType.decode(result["state"])
	# The live viewer's own incident configuration: decode() always builds
	# with incidents disabled, so a startup restore must
	# re-apply it the same way _init()'s fresh build does, or a resumed colony
	# silently loses its daily incidents and Spawn buttons.
	new_world.enable_incidents()
	_replace_world(new_world)
	_startup_resume_message = _resume_message(result)

## Fixed screen regions: wrapping toolbar, clipped map, independently
## scrollable information/work panel. No camera transform reaches the HUD.
func _build_ui() -> void:
	var layout := VBoxContainer.new()
	layout.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(layout)
	_controls = HFlowContainer.new()
	layout.add_child(_controls)
	for entry in [
		["controls.pause", _on_pause_pressed], ["controls.step", _on_step_pressed],
		["controls.speed_x1", _on_speed_x1_pressed], ["controls.speed_x2", _on_speed_x2_pressed],
		["controls.speed_x3", _on_speed_x3_pressed], ["controls.save", _on_save_pressed],
		["controls.load", _on_load_pressed], ["controls.center", _on_center_pressed],
		["controls.navigate", func(): _select_tool(-1)], ["controls.toggle_art", _on_toggle_art_pressed]]:
		_controls.add_child(_make_button(entry[0], entry[1]))
	# New game controls: a visible, editable numeric seed --
	# left blank, _on_new_game_pressed() picks one and writes it back here so
	# it stays documented/visible, never silently chosen (see
	# docs/decisions/019-world-dimensions-and-generation.md). Hard-coded
	# English labels; not yet routed through the text table.
	_seed_input = LineEdit.new()
	_seed_input.placeholder_text = "Seed (blank = random)"
	_seed_input.custom_minimum_size.x = 160
	_controls.add_child(_seed_input)
	_controls.add_child(_make_button_text("New Game", _on_new_game_pressed))
	# Explicit opt-in to the seeded diagnostic scenario, which is kept as an
	# option and for fixtures but is never the default -- the random dig-order queue
	# and forced furniture DebugScenarioType.build() places are reachable from
	# the running viewer only by pressing this button, never at startup.
	_controls.add_child(_make_button_text("Debug Scenario", _on_debug_scenario_pressed))
	# The active world's own seed, distinct from
	# _seed_input above: that field is an editable draft for the next New
	# Game, overwritten by _on_new_game_pressed() and never touched by Load,
	# so it goes stale/misleading the moment a different colony is restored.
	# This label always reflects whichever WorldState is actually running --
	# set below for the world built at startup, and refreshed by
	# _replace_world() every time Load or New Game swaps it.
	_active_seed_label = Label.new()
	_controls.add_child(_active_seed_label)
	var keys := ["dig", "chop", "forage", "cancel", "wall", "remove_object", "zone", "till", "sow", "mine"]
	for tool in keys.size():
		var button := _make_button("controls.tool_" + keys[tool], _select_tool.bind(tool))
		button.toggle_mode = true
		_tool_buttons[tool] = button
		_controls.add_child(button)
	var wall_kinds := ButtonGroup.new()
	for kind in ["wooden_wall", "stone_wall"]:
		var button := _make_button("controls." + kind, _select_wall_kind.bind(kind))
		button.toggle_mode = true
		button.button_group = wall_kinds
		button.set_pressed_no_signal(kind == _wall_kind)
		_wall_kind_buttons[kind] = button
		_controls.add_child(button)
	for entry in [["Build Door", Tool.BUILD_DOOR], ["Build Bed", Tool.BUILD_BED], ["Build Workbench", Tool.BUILD_WORKBENCH]]:
		var build_button := _make_button_text(String(entry[0]), _select_tool.bind(int(entry[1])))
		build_button.toggle_mode = true
		_tool_buttons[entry[1]] = build_button
		_controls.add_child(build_button)
	_rotate_build_button = _make_button_text("Rotate (R)", _on_rotate_build_pressed)
	_rotate_build_button.toggle_mode = true
	_rotate_build_button.disabled = true
	_controls.add_child(_rotate_build_button)
	for incident_button in _make_incident_buttons():
		_controls.add_child(incident_button)
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
	_map_view.rectangle_committed.connect(_on_map_rectangle_committed)
	_map_view.zone_add_committed.connect(_on_map_zone_add_committed)
	_map_view.build_committed.connect(_on_map_build_committed)
	_map_view.tool_left.connect(func(): _select_tool(-1))
	_map_view.preview_validity = _preview_validity
	_map_viewport.attach(_map_view)
	_ui_scroll = ScrollContainer.new()
	_ui_scroll.custom_minimum_size.x = 360
	body.add_child(_ui_scroll)
	_ui_content = VBoxContainer.new()
	_ui_content.custom_minimum_size = Vector2(620, 1000)
	_ui_scroll.add_child(_ui_content)
	_status_label = Label.new()
	_ui_content.add_child(_status_label)
	if _startup_resume_message != "":
		_status_label.text = _startup_resume_message
	else:
		_update_last_saved_label()
	_ui_content.add_child(_rejected_tiles_label)
	_ui_content.add_child(_need_alerts_label)
	_ui_content.add_child(_room_label)
	_update_need_alerts_label()
	_update_active_seed_label()
	_work_table_panel = WorkTablePanelType.new()
	_work_table_panel.custom_minimum_size = Vector2(620, 330)
	_work_table_panel.setup(world, _text_table)
	_ui_content.add_child(_work_table_panel)
	_colonist_panel = ColonistPanelType.new()
	_colonist_panel.custom_minimum_size = Vector2(620, 650)
	_colonist_panel.setup(world, _text_table)
	_ui_content.add_child(_colonist_panel)
	_new_game_confirm = ConfirmationDialog.new()
	_new_game_confirm.title = "New Game"
	_new_game_confirm.confirmed.connect(_on_new_game_confirmed)
	add_child(_new_game_confirm)
	_map_viewport.call_deferred("center_colonists")

func _on_center_pressed() -> void:
	_map_viewport.center_colonists()

## Runs the exact same command rules apply() would (WorldState.preview()) without
## mutating state or round-tripping through StateCodec: a read-only dry run per tile, in exactly
## commit order. Preview introduces neither duplicated rules nor live events.
func _preview_validity(tiles: Array[Vector2i]) -> Array[bool]:
	var result: Array[bool] = []
	if _selected_tool == Tool.WALL:
		var outcome: Dictionary = world.preview(_wall_command(tiles))
		var skipped := {}
		for entry in outcome.get("skipped", []):
			skipped[Vector2i(entry["x"], entry["y"])] = true
		for tile in tiles:
			result.append(bool(outcome.get("ok", false)) and not skipped.has(tile))
	elif _selected_tool == Tool.ZONE:
		var first := tiles[0]
		var last := tiles[-1]
		var outcome: Dictionary = world.preview({
			"actor": "player", "command_id": "preview_zone", "tick": world.get_tick(), "type": "zone_add",
			"payload": {"x": first.x, "y": first.y, "width": last.x - first.x + 1, "height": last.y - first.y + 1}})
		for tile in tiles:
			result.append(outcome.get("ok", false))
	else:
		var is_footprint_preview := _build_kind_for_tool(_selected_tool) == "workbench" and tiles.size() == 2
		if is_footprint_preview:
			var origin := tiles[0]
			var delta := Vector2i.DOWN if _build_orientation() == "vertical" else Vector2i.RIGHT
			is_footprint_preview = tiles[1] == origin + delta
		if is_footprint_preview:
			var command := _command_for_tile(_selected_tool, tiles[0])
			var valid: bool = not command.is_empty() and bool(world.preview(command).get("ok", false))
			for tile in tiles:
				result.append(valid)
		else:
			for tile in tiles:
				var command := _command_for_tile(_selected_tool, tile)
				result.append(not command.is_empty() and world.preview(command).get("ok", false))
	return result

func _on_ticked() -> void:
	autosave_trigger.check(world.get_tick())
	_refresh()

func _refresh() -> void:
	if _map_view != null:
		_map_view.refresh()
	if _colonist_panel != null:
		_colonist_panel.refresh()
	if _work_table_panel != null:
		_work_table_panel.refresh()
	_update_need_alerts_label()
	_refresh_room_label()

const NEED_UNMET_PREFIX := "need_unmet:"
const NEED_SOURCE_MISSING_PREFIX := "need_source_missing:"

## Standing alert list (colonist-ai.md sections 3.1, 3.8 and 4): every
## colonist currently exposing need_unmet:<kind> or need_source_missing:<kind>
## (WorldState.get_colonist_need_reason()), one line each, id-sorted, followed
## by every incident_started event WorldState.get_events() has recorded so far
## -- an incident is a one-time historical
## fact rather than an ongoing condition, so unlike the need lines above it is
## never dropped once shown, only appended to as new incidents fire. Rebuilt
## from scratch every refresh instead of appended to, so the need portion of
## the list never grows tick over tick and a colonist drops off it the instant
## its reason clears -- the same replace-not-append pattern
## _update_rejected_tiles_label() already uses. Presentation-only: no
## simulation rule lives here, it only reads WorldState's existing getters.
func _update_need_alerts_label() -> void:
	if _need_alerts_label == null:
		return
	var lines: Array[String] = []
	var colonists := world.get_colonists()
	colonists.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a["id"] < b["id"])
	for colonist in colonists:
		var colonist_id: String = colonist["id"]
		var reason := world.get_colonist_need_reason(colonist_id)
		var label_key := ""
		var kind := ""
		if reason.begins_with(NEED_UNMET_PREFIX):
			label_key = "status.alert_need_unmet_label"
			kind = reason.substr(NEED_UNMET_PREFIX.length())
		elif reason.begins_with(NEED_SOURCE_MISSING_PREFIX):
			label_key = "status.alert_need_source_missing_label"
			kind = reason.substr(NEED_SOURCE_MISSING_PREFIX.length())
		else:
			continue
		var kind_text := _text_table.get_string("status.need.%s" % kind)
		lines.append(_text_table.format(label_key, [colonist_id, kind_text]))
	for event in world.get_events():
		if String(event.get("type", "")) != "incident_started":
			continue
		lines.append(_incident_started_alert_line(event))
	_need_alerts_label.text = "\n".join(lines)

## Hard-coded English text; not yet routed through the text table (like the
## New Game controls above).
func _incident_started_alert_line(event: Dictionary) -> String:
	var data: Dictionary = event.get("data", {})
	return "Incident: %s (%s)" % [String(data.get("incident_id", "")), String(data.get("faction", ""))]

func _make_button(text_key: String, on_pressed: Callable) -> Button:
	var button := Button.new()
	button.text = _text_table.get_string(text_key)
	button.pressed.connect(on_pressed)
	return button

## Like _make_button() but with literal text instead of a text-table key
## (used for the hard-coded English labels such as the New Game button).
func _make_button_text(text: String, on_pressed: Callable) -> Button:
	var button := Button.new()
	button.text = text
	button.pressed.connect(on_pressed)
	return button

func _command_for_tile(tool: int, tile: Vector2i) -> Dictionary:
	if tool == Tool.CANCEL:
		var site := world.get_construction_site(tile.x, tile.y)
		if not site.is_empty():
			return {
				"actor": "player", "command_id": "viewer_cancel_site_%s" % site["id"],
				"tick": world.get_tick(), "type": "cancel_site",
				"payload": {"x": int(site["origin"].x), "y": int(site["origin"].y)},
			}
		var candidate := _cancel_job_for_tile(tile)
		if candidate.is_empty():
			return {}
		return {
			"actor": "player", "command_id": "viewer_cancel_%s" % candidate["id"],
			"tick": world.get_tick(), "type": "cancel_job",
			"payload": {"job_id": candidate["id"]},
		}
	if tool == Tool.REMOVE_OBJECT:
		return {
			"actor": "player",
			"command_id": "viewer_remove_object_%d_%d_%d" % [world.get_tick(), tile.x, tile.y],
			"tick": world.get_tick(),
			"type": "remove_object",
			"payload": {"x": tile.x, "y": tile.y},
		}
	# Build tools: the same command map_view.gd's
	# click path submits, so _preview_validity()'s hover colouring runs the
	# identical read-only rule (WorldState.preview() -> _check_build_command()).
	var build_kind := _build_kind_for_tool(tool)
	if not build_kind.is_empty():
		var payload := {"kind": build_kind, "x": tile.x, "y": tile.y}
		if _build_kind_is_rotatable(build_kind):
			payload["orientation"] = _map_view.get_build_orientation() if _map_view != null else "horizontal"
		return {
			"actor": "player",
			"command_id": "viewer_build_%s_%d_%d_%d" % [build_kind, world.get_tick(), tile.x, tile.y],
			"tick": world.get_tick(),
			"type": "build",
			"payload": payload,
		}
	var command_type := (
		"dig" if tool == Tool.DIG
		else "chop" if tool == Tool.CHOP
		else "forage" if tool == Tool.FORAGE
		else "till" if tool == Tool.TILL
		else "sow" if tool == Tool.SOW
		else "mine" if tool == Tool.MINE
		else ""
	)
	if command_type.is_empty():
		return {}
	return {
		"actor": "player",
		"command_id": "viewer_%s_%d_%d_%d" % [command_type, world.get_tick(), tile.x, tile.y],
		"tick": world.get_tick(),
		"type": command_type,
		"payload": {"x": tile.x, "y": tile.y, "priority": 1},
	}

## The tile a pending order is interacted with at: a site_fetch/site_work
## job's construction site (its "target" is the fetch source tile or the
## site itself, but "site" always names the site); for any other job, its
## target.
func _order_tile(job: Dictionary) -> Vector2i:
	if job.get("site") != null:
		return job["site"]
	return job["target"]

## A construction site has no job at all until ConstructionGiver submits one
## on its own per-tick schedule (ADR 040), so ordering a build and
## cancelling it before the next tick must still resolve to something: falls
## back to the site record itself, keyed by any of its footprint tiles
## (get_construction_site()) -- WorldState._apply_cancel_job_command()
## recognises the same site id standing in for a job id.
func _cancel_job_for_tile(tile: Vector2i) -> Dictionary:
	var best := {}
	for job in world.get_jobs():
		if job["status"] not in ["queued", "active"] or _order_tile(job) != tile:
			continue
		if best.is_empty() or _cancel_job_before(job, best):
			best = job
	if not best.is_empty():
		return best
	var site := world.get_construction_site(tile.x, tile.y)
	if not site.is_empty():
		return {"id": site["id"]}
	return {}

func _cancel_job_before(candidate: Dictionary, current: Dictionary) -> bool:
	var candidate_status := 0 if candidate["status"] == "queued" else 1
	var current_status := 0 if current["status"] == "queued" else 1
	if candidate_status != current_status:
		return candidate_status < current_status
	if int(candidate["priority"]) != int(current["priority"]):
		return int(candidate["priority"]) > int(current["priority"])
	return String(candidate["id"]) < String(current["id"])

func _on_map_rectangle_committed(tiles: Array[Vector2i]) -> void:
	_commit_rectangle(tiles)

## Walls apply one build_line for the complete rectangle. Other tools apply
## one command per tile, in the given (row-major) order. A tile with
## no command to build (e.g. Cancel over a tile with no matching job) is
## silently skipped, same as a single click always has been -- it is not a
## rejection. Every tile whose command world.apply() rejects is returned so
## the caller (and tests) can inspect the reason without depending on UI.
func _commit_rectangle(tiles: Array[Vector2i]) -> Array[Dictionary]:
	var rejected: Array[Dictionary] = []
	if _selected_tool == Tool.WALL and not tiles.is_empty():
		var result: Dictionary = world.apply(_wall_command(tiles))
		if not result.get("ok", false):
			for tile in tiles:
				rejected.append({"tile": tile, "reason": String(result["rejection"]["reason"])})
		else:
			for entry in result.get("skipped", []):
				rejected.append({"tile": Vector2i(entry["x"], entry["y"]), "reason": entry["reason"]})
	else:
		for tile in tiles:
			var command := _command_for_tile(_selected_tool, tile)
			if command.is_empty():
				continue
			var result: Dictionary = world.apply(command)
			if not result.get("ok", false):
				rejected.append({"tile": tile, "reason": String(result["rejection"]["reason"])})
	if not tiles.is_empty():
		_inspected_tile = tiles[tiles.size() - 1]
		_has_inspected_tile = true
	_refresh()
	_update_rejected_tiles_label(rejected)
	return rejected

## Rooms: presentation-only readout of the last selected tile's room
## (docs/architecture/extension-points.md "Presentation") -- reads
## WorldState.get_room_at() and picks a name, Bedroom over Storeroom over
## plain Room, adding no simulation rule of its own. Recomputed from
## _inspected_tile on every _refresh() (tick-driven state changes, a zone
## command, committing a tile rectangle) and after loading another world, so
## the label always reflects live state instead of freezing at whatever it
## last showed -- unlike _update_rejected_tiles_label(), which only ever
## replaces on a fresh command outcome, room membership can change out from
## under an inspected tile with no new command aimed at it at all (an
## overlapping zone_add, a wall breached or resealed elsewhere).
func _refresh_room_label() -> void:
	if _room_label == null:
		return
	if not _has_inspected_tile:
		_room_label.text = ""
		return
	var room := world.get_room_at(_inspected_tile.x, _inspected_tile.y)
	if room.is_empty():
		_room_label.text = ""
		return
	var room_name := "Room"
	if bool(room.get("has_bed", false)):
		room_name = "Bedroom"
	elif bool(room.get("has_stockpile", false)):
		room_name = "Storeroom"
	_room_label.text = "%s (%d tiles, %d doors)" % [room_name, int(room["size"]), int(room["door_count"])]

## Replaces (never appends to) the rejected-tiles block on every commit, so a
## later successful drag clears an earlier rejection instead of accumulating.
func _update_rejected_tiles_label(rejected: Array[Dictionary]) -> void:
	if _rejected_tiles_label == null:
		return
	var lines: Array[String] = []
	for entry in rejected:
		var tile: Vector2i = entry["tile"]
		var reason_text := _text_table.get_string("status.reason.%s" % entry["reason"])
		lines.append(_text_table.format("status.rejected_tile_label", [tile.x, tile.y, reason_text]))
	_rejected_tiles_label.text = "\n".join(lines)

## "" for a tool that isn't one of the build buttons, else the
## content/objects.json kind that tool builds.
func _build_kind_for_tool(tool: int) -> String:
	match tool:
		Tool.BUILD_DOOR: return "door"
		Tool.BUILD_BED: return "bed"
		Tool.BUILD_WORKBENCH: return "workbench"
		_: return ""

## The same complete batch is used for read-only preview and release submission.
func _wall_command(tiles: Array[Vector2i]) -> Dictionary:
	var payload_tiles: Array[Dictionary] = []
	for tile in tiles:
		payload_tiles.append({"x": tile.x, "y": tile.y})
	return {"actor": "player", "command_id": "viewer_wall_%d" % world.get_tick(),
		"tick": world.get_tick(), "type": "build_line",
		"payload": {"kind": _wall_kind, "tiles": payload_tiles}}

func _select_wall_kind(kind: String) -> void:
	_wall_kind = kind
	for key in _wall_kind_buttons:
		_wall_kind_buttons[key].set_pressed_no_signal(key == kind)
	if _map_view != null and _selected_tool == Tool.WALL:
		_map_view.set_build_kind(kind)
		_map_view.refresh()

func _build_orientation() -> String:
	return _map_view.get_build_orientation() if _map_view != null else "horizontal"

func _select_tool(tool: int) -> void:
	_selected_tool = tool
	for key in _tool_buttons:
		_tool_buttons[key].set_pressed_no_signal(key == tool)
	if _map_view != null:
		_map_view.set_tool_enabled(tool >= 0)
		_map_view.set_zone_tool_enabled(tool == Tool.ZONE)
		var build_kind := _build_kind_for_tool(tool)
		_map_view.set_build_tool_enabled(not build_kind.is_empty())
		if tool == Tool.WALL:
			_map_view.set_build_kind(_wall_kind)
		if not build_kind.is_empty():
			_map_view.set_build_kind(build_kind)
			_map_view.set_build_rotatable(_build_kind_is_rotatable(build_kind))
		if _rotate_build_button != null:
			var rotatable := _build_kind_is_rotatable(build_kind)
			_rotate_build_button.disabled = not rotatable
			_rotate_build_button.set_pressed_no_signal(_map_view.is_build_vertical() if rotatable else false)

func _on_rotate_build_pressed() -> void:
	if _map_view == null or not _build_kind_is_rotatable(_build_kind_for_tool(_selected_tool)):
		return
	_map_view.toggle_build_orientation()
	_rotate_build_button.set_pressed_no_signal(_map_view.is_build_vertical())

func _build_kind_is_rotatable(kind: String) -> bool:
	if world == null:
		return false
	for entry in world._content.list("objects"):
		if String(entry.get("kind", "")) == kind:
			return bool(entry.get("rotatable", false))
	return false

func _on_tool_dig_pressed() -> void:
	_select_tool(Tool.DIG)

func _on_tool_chop_pressed() -> void:
	_select_tool(Tool.CHOP)

func _on_tool_forage_pressed() -> void:
	_select_tool(Tool.FORAGE)

func _on_tool_till_pressed() -> void:
	_select_tool(Tool.TILL)

func _on_tool_sow_pressed() -> void:
	_select_tool(Tool.SOW)

func _on_tool_cancel_pressed() -> void:
	_select_tool(Tool.CANCEL)

func _on_tool_remove_object_pressed() -> void:
	_select_tool(Tool.REMOVE_OBJECT)

func _on_tool_zone_pressed() -> void:
	_select_tool(Tool.ZONE)

## The zone tool draws through _map_view's own single zone_add-per-drag path
## (see map_view.gd's zone_add_committed signal) instead of
## _command_for_tile()/_commit_rectangle() above, since a zone is one
## command for the whole rectangle, not one per tile. Mirrors
## _update_rejected_tiles_label()'s ok/rejected handling for that path: a
## rejection shows its reason, and a later successful drag clears it.
func _on_map_zone_add_committed(result: Dictionary) -> void:
	_refresh_room_label()
	if _rejected_tiles_label == null:
		return
	if result.get("ok", false):
		_rejected_tiles_label.text = ""
		return
	var reason_text := _text_table.get_string("status.reason.%s" % result["rejection"]["reason"])
	_rejected_tiles_label.text = _text_table.format("status.zone_rejected_label", [reason_text])

## The build tool's own click-to-place path (map_view.gd's build_committed
## signal), mirroring _on_map_zone_add_committed()'s ok/rejected handling.
## Hard-coded English text; not yet routed through the text table (like this
## file's other literal strings above).
func _on_map_build_committed(result: Dictionary) -> void:
	_refresh_room_label()
	if _rejected_tiles_label == null:
		return
	if result.get("ok", false):
		_rejected_tiles_label.text = ""
		return
	_rejected_tiles_label.text = "Build rejected: %s" % String(result["rejection"]["reason"])

func _on_toggle_art_pressed() -> void:
	_map_view.toggle_art_enabled()

## One debug button per content/incidents.json row, each
## dispatching spawn_incident(id) below, so an incident can be triggered
## from the running viewer. Built by _ready() into the control bar, and by
## test_incidents.gd directly (a headless test never runs _ready()).
func _make_incident_buttons() -> Array[Button]:
	var buttons: Array[Button] = []
	for entry in world._content.list("incidents"):
		var incident_id := String(entry["id"])
		var button := Button.new()
		button.text = _incident_display_name(incident_id)
		button.tooltip_text = "Debug: trigger this incident now"
		button.set_meta("incident_id", incident_id)
		button.pressed.connect(spawn_incident.bind(incident_id))
		buttons.append(button)
	return buttons

## The viewer's spawn_incident dispatch: the debug buttons
## above call this; test_incidents.gd presses them. Returns
## WorldState.apply()'s own result so a caller can inspect it.
func spawn_incident(incident_id: String) -> Dictionary:
	var result: Dictionary = world.apply({
		"actor": "player", "command_id": "viewer_spawn_incident_%s_%d" % [incident_id, world.get_tick()],
		"tick": world.get_tick(), "type": "spawn_incident", "payload": {"id": incident_id},
	})
	if _status_label != null:
		var display_name := _incident_display_name(incident_id)
		if result.get("ok", false):
			_status_label.text = "%s: started." % display_name
		else:
			_status_label.text = "%s: not started (%s)." % [display_name, String(result.get("rejection", {}).get("reason", ""))]
	return result

## Player-facing name of an incident: its "incident.<id>" text-table entry,
## or the id with underscores replaced and the first letter capitalised when
## a content incident has no entry yet.
func _incident_display_name(incident_id: String) -> String:
	var key := "incident." + incident_id
	if _text_table == null:
		_text_table = TextTableType.new(TEXT_TABLE_PATH)
	if _text_table.has_string(key):
		return _text_table.get_string(key)
	var words := incident_id.replace("_", " ")
	return words.substr(0, 1).to_upper() + words.substr(1)

func _on_pause_pressed() -> void:
	tick_driver.pause()

func _on_step_pressed() -> void:
	tick_driver.step_once()

func _on_speed_x1_pressed() -> void:
	tick_driver.set_speed(TickDriverType.Speed.X1)

func _on_speed_x2_pressed() -> void:
	tick_driver.set_speed(TickDriverType.Speed.X2)

func _on_speed_x3_pressed() -> void:
	tick_driver.set_speed(TickDriverType.Speed.X3)

func _on_save_pressed() -> void:
	var result: Dictionary = save_manager.save_manual(world, _current_epoch)
	if result.get("ok", false):
		# The player has now explicitly committed this game to disk: autosave
		# may safely resume (or keep running) for it --
		# a no-op when it was already enabled.
		autosave_trigger.set_enabled(true)
	_handle_save_result(result)

func _on_load_pressed() -> void:
	var result: Dictionary = save_manager.load_best()
	if not result.get("ok", false):
		if _status_label != null:
			_status_label.text = _text_table.get_string("status.load_failed")
		return
	_current_epoch = int(result.get("epoch", 0))
	var new_world: WorldStateType = StateCodecType.decode(result["state"])
	# Same reasoning as _restore_from_save(): a manual Load must re-enable
	# incidents on the restored world too, not just the fresh boot build.
	new_world.enable_incidents()
	_replace_world(new_world)
	if _status_label != null:
		_status_label.text = _resume_message(result)

func _on_autosaved(result: Dictionary) -> void:
	_handle_save_result(result)

## Resolves the seed field (blank picks one via the application layer's own
## global RNG -- never core, see simulation-boundaries.md) and writes the
## resolved value back so it stays visible/documented, then asks for
## confirmation before regenerating the live world.
func _on_new_game_pressed() -> void:
	var seed_text := _seed_input.text.strip_edges()
	var seed_value: int
	if seed_text.is_empty():
		seed_value = randi()
	elif seed_text.is_valid_int():
		seed_value = seed_text.to_int()
	else:
		if _status_label != null:
			_status_label.text = "Seed must be a whole number, or blank for a random one."
		return
	_seed_input.text = str(seed_value)
	_pending_new_game_seed = seed_value
	_new_game_confirm.dialog_text = "Start a new game with seed %d? Your last save is kept until you press Save." % seed_value
	_new_game_confirm.popup_centered()

func _on_new_game_confirmed() -> void:
	_start_new_game(_pending_new_game_seed)

## Explicit diagnostic opt-in: swaps in DebugScenarioType's own
## seeded scenario (random dig-order queue, forced wall/furniture/berry_bush/
## bed row, a pre-plowed/seeded farm plot) exactly like Load/New Game swap in
## any other world, through the same _replace_world() path -- never the
## viewer's default. Mints a new epoch and suspends autosave the same way
## _start_new_game() does, since this is a distinct, unsaved colony too.
func _on_debug_scenario_pressed() -> void:
	var new_world := DebugScenarioType.build(DebugScenarioType.SCENARIO_SEED, DebugScenarioType.TICK_RATE, true)
	_current_epoch = maxi(_current_epoch, save_manager.highest_known_epoch()) + 1
	_replace_world(new_world)
	autosave_trigger.set_enabled(false)
	tick_driver.pause()
	if _status_label != null:
		_status_label.text = "Debug scenario: seed %d." % DebugScenarioType.SCENARIO_SEED

## Builds a fresh WorldState at mapgen.json's default_new_game_width/height
## (256x256) the same way build_default_world() does, and swaps it
## in exactly like Load does -- never touches save_manager, so the previous
## save is left exactly as it was until the player explicitly presses Save.
## Mints a strictly new epoch (see _current_epoch's own doc comment), suspends
## autosaving until that explicit Save happens (otherwise a ticking but
## unsaved new game could silently rotate into an existing autosave slot
## from the game just replaced, contradicting the New Game confirmation's
## promise), and starts paused.
func _start_new_game(seed_value: int) -> void:
	var new_world := build_default_world(seed_value, 10)
	_current_epoch = maxi(_current_epoch, save_manager.highest_known_epoch()) + 1
	_replace_world(new_world)
	autosave_trigger.set_enabled(false)
	tick_driver.pause()
	if _status_label != null:
		_status_label.text = "New game: seed %d (%dx%d)." % [seed_value, new_world.get_map_width(), new_world.get_map_height()]

## Deterministic starting prerequisites: every job kind that
## declares a needs_tool requirement in jobs.json (dig -> pick, chop -> axe)
## gets one ground tool item within the world's own real spawn clearing
## (WorldGenerator.place_spawn()'s river-aware, resource-validated
## search, not mapgen.json's spawn_area_x/y -- that field is now only the
## absolute-last-resort fallback anchor a total search failure would use, see
## ADR 020), through the same spawn_ground_tool_item()/fetch_tool
## toil path a player-placed or world-generated tool would use -- never a
## bypass of the work engine's tool-fetch requirement, just a real tool
## actually present to fetch. Tool kinds are sorted for a placement order
## independent of jobs.json's own field order, so this stays deterministic
## for a given seed. Static (no instance state used) so build_default_world()
## can call it without a Boot node.
##
## Reading clearing_x/clearing_y/clearing_width and computing
## `clearing_x + i % clearing_width` blindly could place a tool on a still-
## water cell whenever a fallback tier's own rectangle metadata was not fully
## painted (or, for a repaired/constructed clearing, was never a solid
## rectangle at all). place_spawn() now returns its own already-vetted,
## never-water, never-colonist-occupied land tile pool (get_spawn_clearing()'s
## "land_tiles") for exactly this purpose; this only falls back to the old
## anchor-offset scheme when that pool is empty (a StateCodec-decoded world,
## which never calls place_spawn() at all and has no clearing/pool to read).
static func _spawn_starting_tools(new_world: WorldStateType, mapgen: Dictionary) -> void:
	var tool_kinds := _needed_tool_kinds()
	var tiles := _claim_starting_tiles(new_world, mapgen, tool_kinds.size() + new_world.get_colonists().size())
	for i in tool_kinds.size():
		var tile: Vector2i = tiles[i] if i < tiles.size() else _fallback_anchor(new_world, mapgen)
		new_world.spawn_ground_tool_item(tool_kinds[i], tile.x, tile.y)

## Every job kind's needs_tool requirement (jobs.json), deduplicated and
## sorted -- shared by _spawn_starting_tools() and _spawn_starting_beds() so
## both agree on exactly how many pool tiles the tools claim, and neither
## recomputes a slightly different count.
static func _needed_tool_kinds() -> Array[String]:
	var tool_kinds: Array[String] = []
	for job_def in ContentRegistryType.new().list("jobs"):
		var needs_tool := String(job_def.get("needs_tool", ""))
		if not needs_tool.is_empty() and not tool_kinds.has(needs_tool):
			tool_kinds.append(needs_tool)
	tool_kinds.sort()
	return tool_kinds

## One "bed" object per colonist: normal generation supplies no other
## rest-need source, so without these the "rest" need in content/needs.json
## (source_kind "bed") would be permanently unmet on every fresh New Game.
## Placed through the same place_object command path a player-built bed would
## use (never a bypass of its own occupancy/tree/colonist validation), on the
## same guaranteed-safe land tile pool _spawn_starting_tools() above draws
## from, offset past however many tiles that call already claimed for tools so
## neither placement can land on the other's tile -- exactly colonist_count
## beds, never the whole remaining pool.
static func _spawn_starting_beds(new_world: WorldStateType, mapgen: Dictionary) -> void:
	var colonist_count := new_world.get_colonists().size()
	var tool_count := _needed_tool_kinds().size()
	var tiles := _claim_starting_tiles(new_world, mapgen, tool_count + colonist_count)
	var bed_tiles := tiles.slice(tool_count, tool_count + colonist_count)
	for i in bed_tiles.size():
		var tile: Vector2i = bed_tiles[i]
		new_world.apply({
			"actor": "system", "command_id": "starting_bed_%d" % i, "tick": new_world.get_tick(),
			"type": "place_object", "payload": {"x": tile.x, "y": tile.y, "kind": "bed"},
		})

## The spawn clearing's own guaranteed-safe land tile pool, shared by _spawn_starting_tools()/_spawn_starting_beds() so both
## draw from the same deterministic list instead of guessing independent
## offsets that could collide with each other or with a colonist's own tile.
## `needed` is a hint only (both callers request their own full-size slice and
## take what they need by position), so a single call here can serve both.
static func _claim_starting_tiles(new_world: WorldStateType, mapgen: Dictionary, needed: int) -> Array[Vector2i]:
	var clearing := new_world.get_spawn_clearing()
	var pool: Array = clearing.get("land_tiles", [])
	var tiles: Array[Vector2i] = []
	for entry in pool:
		tiles.append(entry as Vector2i)
	if not tiles.is_empty() or needed <= 0:
		return tiles
	var anchor := _fallback_anchor(new_world, mapgen)
	for i in needed:
		tiles.append(anchor)
	return tiles

## Only reached for a StateCodec-decoded world (get_spawn_clearing() empty,
## never calls place_spawn()) or a pathological clearing with no land tile
## pool at all -- mapgen.json's own documented last-resort anchor, clamped
## in-bounds.
static func _fallback_anchor(new_world: WorldStateType, mapgen: Dictionary) -> Vector2i:
	return Vector2i(
		clampi(int(mapgen.get("spawn_area_x", 0)), 0, maxi(0, new_world.get_map_width() - 1)),
		clampi(int(mapgen.get("spawn_area_y", 0)), 0, maxi(0, new_world.get_map_height() - 1))
	)

## Every save_manual()/save_autosave() result is inspected here -- ok or not
## -- so a typed write failure (write_failed, write_interrupted, ...) is
## always shown instead of silently dropped. The last-saved status line only
## advances on a successful save; a failed one leaves it (and the last
## known-good save on disk) exactly as it was.
func _handle_save_result(result: Dictionary) -> void:
	if _status_label == null:
		return
	if result.get("ok", false):
		_update_last_saved_label()
		return
	var code := String(result.get("code", "unknown"))
	var reason := _text_table.get_string("save.write_reason.%s" % code)
	_status_label.text = _text_table.format("status.save_failed", [reason])

## Swaps the running world into every place that holds a reference to it.
## map_view/colonist_panel/tick_driver already expose plain public setters
## or fields for this; nothing here mutates simulation state, it only
## repoints presentation and the tick/autosave drivers at the newly loaded
## WorldState returned by StateCodec.decode().
func _replace_world(new_world: WorldStateType) -> void:
	world = new_world
	tick_driver.world = new_world
	autosave_trigger.attach(new_world, save_manager, _current_epoch)
	if _map_view != null:
		_map_view.set_world(new_world)
		# Reapplies camera bounds for the newly attached world's own dimensions.
		# Without this, panning to a large world's far corner
		# and then loading/starting a smaller one left the camera at its old,
		# now out-of-range position, leaving the viewport blank until another
		# pan/zoom. center_colonists() already calls cancel_gesture() first.
		_map_viewport.center_colonists()
	if _colonist_panel != null:
		_colonist_panel.world = new_world
		_colonist_panel.refresh()
	if _work_table_panel != null:
		_work_table_panel.world = new_world
		_work_table_panel.refresh()
	_update_need_alerts_label()
	_update_active_seed_label()
	_refresh_room_label()

## The running world's own documented seed:
## refreshed here and by _replace_world() so it always names whichever
## WorldState is actually live, unlike _seed_input (an editable draft for the
## next New Game -- see its comment in _build_ui()).
func _update_active_seed_label() -> void:
	if _active_seed_label == null:
		return
	_active_seed_label.text = "Active seed: %d" % world.get_seed()

func _update_last_saved_label() -> void:
	if _status_label == null:
		return
	var good = save_manager.get_last_known_good()
	if good == null:
		_status_label.text = _text_table.get_string("status.last_saved_none")
	else:
		_status_label.text = _text_table.format("status.last_saved_label", [int(good["tick"])])

## Builds a "resumed from autosave 2 (tick N) because autosave 1 was
## unreadable" style message: names the slot actually used, and -- only when
## load_best() had to skip a newer candidate to get there -- the first
## skipped slot's own typed reason, read straight from SaveIO's failure
## code rather than re-derived here.
func _resume_message(result: Dictionary) -> String:
	var winning := _pretty_slot(String(result["slot"]))
	var tick := int(result["tick"])
	var skipped: Array = result.get("skipped", [])
	if skipped.is_empty():
		return _text_table.format("status.resumed_clean", [winning, tick])
	var first_skip: Dictionary = skipped[0]
	var skipped_pretty := _pretty_slot(String(first_skip["slot"]))
	var reason := _text_table.get_string("save.reason.%s" % String(first_skip.get("code", "unknown")))
	return _text_table.format("status.resumed_with_skip", [winning, tick, skipped_pretty, reason])

func _pretty_slot(slot: String) -> String:
	if slot == SaveManagerType.MANUAL_SLOT:
		return _text_table.get_string("save.slot.manual")
	return slot.replace("-", " ")
