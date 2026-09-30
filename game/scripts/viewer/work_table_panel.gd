extends Control

## Work-priority table (colonist-ai.md 3.2/3.7/3.8):
## one row per colonist (world.get_colonists()), one column per labour kind
## (WorldState.LABOUR_KINDS -- referenced, not copied, so this table always
## matches the core vocabulary), each cell showing that colonist's current
## labourTable level. Tapping/clicking a cell cycles its level in the
## documented order 3 -> 4 -> off(0) -> 1 -> 2 -> 3 and issues the existing
## set_labour command through world.apply() -- the only mutation this file
## performs, exactly like every other file under scripts/viewer/ (enforced
## by test_architecture_rules.gd's viewer-purity check: no call on `world`
## beyond a get_* getter, apply(), get_events() or tick()). Cycling is just
## "+1, wrapping at LABOUR_MAX back to LABOUR_MIN": 3,4,0,1,2,3 is that same
## sequence read starting from the default level (colonist-ai.md 3.2's
## "default all 3"), not a special-cased table.
##
## Each labour column's header also shows that labour's active calendar
## boost (world.get_active_calendar_boost(), colonist-ai.md 3.7: "the work
## table shows these active boosts") whenever it is non-zero.
##
## The banner shows the most recent calendar_alert event from
## world.get_events() (colonist-ai.md 3.7/ADR 008) until the player
## dismisses it, or a *different* calendar_alert event becomes the most
## recent one. WorldState exposes no public getter for a calendar window's
## own "to" day or the current day number (get_active_calendar_boost() only
## answers "is a boost active right now", never "when does this window
## close"), so day-based auto-expiry is deferred until a core change exposes
## that information. This file never
## builds its own CalendarService or reads content/calendar.json -- ADR 010
## reserves content loading to ContentRegistry's frozen bundle, already
## injected into WorldState's own calendar service; a second, panel-local
## read of the same file would be exactly the drift ADR 010 forbids. The only
## calendar-shaped fact read here is get_active_calendar_boost() plus
## whatever world.get_events() already replayed.
##
## Refresh performance: boot.gd calls refresh() on
## every simulation tick. Queueing every cell button for deletion and
## creating replacements on every such call would let a real press-then-
## release spanning a tick lose its button mid-press (the default
## release-triggered `pressed` signal never fires on a freed node).
## refresh() therefore only rebuilds rows when the colonist id set itself
## changes (a colonist added or removed); the common case -- an ordinary,
## tick-driven refresh -- just updates each already-alive button/label's
## text in place, so a button the player is mid-press on is always the exact
## same node before and after.

const WorldStateType = preload("res://scripts/core/world_state.gd")
const TextTableType = preload("res://scripts/viewer/text_table.gd")

const LABOUR_KINDS = WorldStateType.LABOUR_KINDS

## Cells sized for touch: comfortably
## above the ~44-48px minimum touch-target guidance most mobile platforms
## document.
const CELL_MIN_SIZE := Vector2(64, 64)

var world: WorldStateType
var _text_table: TextTableType
var _grid: GridContainer
var _banner_label: Label
var _banner_button: Button
## Dedupe key ("<window id>@<tick>") for the calendar_alert event currently
## reflected in the banner, so a repeated refresh() with the same event does
## not reset an already-acknowledged banner back to visible.
var _current_alert_key: String = ""
var _banner_acknowledged: bool = false
## Cell buttons keyed "<colonist_id>:<labour>", kept alive across ordinary
## refreshes (see file doc comment) -- only _rebuild_grid() replaces them.
var _cell_buttons: Dictionary = {}
## Column header Labels keyed by labour kind, updated in place every refresh
## to reflect that labour's current calendar boost.
var _header_labels: Dictionary = {}
## The colonist id set (sorted) the grid was last built for; refresh() only
## calls _rebuild_grid() again when this set has actually changed.
var _known_colonist_ids: Array[String] = []
var _command_sequence: int = 0

func setup(world_ref: WorldStateType, text_table: TextTableType) -> void:
	world = world_ref
	_text_table = text_table

	var layout := VBoxContainer.new()
	add_child(layout)

	var banner_row := HBoxContainer.new()
	layout.add_child(banner_row)
	_banner_label = Label.new()
	banner_row.add_child(_banner_label)
	_banner_button = Button.new()
	_banner_button.text = _text_table.get_string("work_table.banner_dismiss")
	_banner_button.pressed.connect(_dismiss_banner)
	banner_row.add_child(_banner_button)

	_grid = GridContainer.new()
	_grid.columns = LABOUR_KINDS.size() + 1
	layout.add_child(_grid)

	refresh()

func refresh() -> void:
	if world == null:
		return
	var colonists := _sorted_colonists()
	var ids := _colonist_ids(colonists)
	if ids != _known_colonist_ids:
		_rebuild_grid(colonists)
		_known_colonist_ids = ids
	else:
		_update_grid_values(colonists)
	_update_banner()

func cell_count() -> int:
	return _cell_buttons.size()

func _cell_button(colonist_id: String, labour: String) -> Button:
	return _cell_buttons.get(_cell_key(colonist_id, labour))

func _cell_key(colonist_id: String, labour: String) -> String:
	return "%s:%s" % [colonist_id, labour]

func _sorted_colonists() -> Array[Dictionary]:
	var colonists: Array[Dictionary] = world.get_colonists()
	colonists.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return String(a["id"]) < String(b["id"]))
	return colonists

func _colonist_ids(colonists: Array[Dictionary]) -> Array[String]:
	var ids: Array[String] = []
	for colonist in colonists:
		ids.append(String(colonist["id"]))
	return ids

## Builds the header row and one row per colonist from scratch. Only called
## from refresh() when the colonist id set has actually changed (a colonist
## added or removed) -- never on an ordinary tick-driven refresh, so a
## button the player is mid-press on is never torn down underneath them.
func _rebuild_grid(colonists: Array[Dictionary]) -> void:
	for child in _grid.get_children():
		child.queue_free()
	_cell_buttons.clear()
	_header_labels.clear()

	var corner := Label.new()
	corner.text = _text_table.get_string("work_table.colonist_header")
	_grid.add_child(corner)
	for labour in LABOUR_KINDS:
		var header := Label.new()
		header.text = _column_header_text(labour)
		_grid.add_child(header)
		_header_labels[labour] = header

	for colonist in colonists:
		var colonist_id := String(colonist["id"])
		var id_label := Label.new()
		id_label.text = colonist_id
		_grid.add_child(id_label)
		var labour_table: Dictionary = colonist.get("labourTable", {})
		for labour in LABOUR_KINDS:
			var level := int(labour_table.get(labour, 0))
			var cell := Button.new()
			cell.text = _level_text(level)
			cell.custom_minimum_size = CELL_MIN_SIZE
			cell.pressed.connect(_on_cell_pressed.bind(colonist_id, labour))
			_grid.add_child(cell)
			_cell_buttons[_cell_key(colonist_id, labour)] = cell

## Updates every already-built cell/header's displayed text in place, without
## touching a single Button/Label node's identity -- the counterpart to
## _rebuild_grid() for the common case (colonist set unchanged).
func _update_grid_values(colonists: Array[Dictionary]) -> void:
	for labour in LABOUR_KINDS:
		var header: Label = _header_labels.get(labour)
		if header != null:
			header.text = _column_header_text(labour)
	for colonist in colonists:
		var colonist_id := String(colonist["id"])
		var labour_table: Dictionary = colonist.get("labourTable", {})
		for labour in LABOUR_KINDS:
			var cell: Button = _cell_buttons.get(_cell_key(colonist_id, labour))
			if cell != null:
				cell.text = _level_text(int(labour_table.get(labour, 0)))

func _column_header_text(labour: String) -> String:
	var text: String = _text_table.get_string("work_table.labour.%s" % labour)
	var boost := world.get_active_calendar_boost(labour)
	if boost != 0:
		text += " " + _text_table.format("work_table.boost_label", [boost])
	return text

func _level_text(level: int) -> String:
	if level == WorldStateType.LABOUR_MIN:
		return _text_table.get_string("work_table.level_off")
	return str(level)

## Cycles colonist_id's `labour` level one step (3 -> 4 -> off(0) -> 1 -> 2 ->
## 3, i.e. +1 wrapping LABOUR_MAX back to LABOUR_MIN) and issues the change
## through the existing set_labour command via world.apply() -- the same
## command scripts/viewer already relies on WorldState to validate.
func _on_cell_pressed(colonist_id: String, labour: String) -> void:
	var colonist := _find_colonist(colonist_id)
	if colonist.is_empty():
		return
	var labour_table: Dictionary = colonist.get("labourTable", {})
	var current := int(labour_table.get(labour, 0))
	var next_level := current + 1
	if next_level > WorldStateType.LABOUR_MAX:
		next_level = WorldStateType.LABOUR_MIN
	_command_sequence += 1
	world.apply({
		"actor": "player",
		"command_id": "viewer_set_labour_%s_%s_%d" % [colonist_id, labour, _command_sequence],
		"tick": world.get_tick(),
		"type": "set_labour",
		"payload": {"colonist": colonist_id, "kind": labour, "level": next_level},
	})
	refresh()

func _find_colonist(colonist_id: String) -> Dictionary:
	for colonist in world.get_colonists():
		if String(colonist["id"]) == colonist_id:
			return colonist
	return {}

## Finds the calendar_alert event with the highest tick in world.get_events()
## (the soonest-upcoming-window alert most recently fired); {} when none has
## fired yet.
func _most_recent_calendar_alert() -> Dictionary:
	var best: Dictionary = {}
	for event in world.get_events():
		if String(event.get("type", "")) != "calendar_alert":
			continue
		if best.is_empty() or int(event["tick"]) >= int(best["tick"]):
			best = event
	return best

func _alert_key(event: Dictionary) -> String:
	var data: Dictionary = event.get("data", {})
	return "%s@%d" % [String(data.get("id", "")), int(event.get("tick", -1))]

## Shows the most recent calendar_alert event's text until the player
## dismisses it (_dismiss_banner()) or a different calendar_alert event
## becomes the most recent one -- whichever comes first. Day-based expiry is
## not implemented yet (see file doc comment); a newly-arrived alert (a
## different dedupe key than the one currently tracked) always resets
## acknowledgement, so a later window's alert is never suppressed by an
## earlier one's dismissal, whether that earlier one was acknowledged yet or
## not.
func _update_banner() -> void:
	var event := _most_recent_calendar_alert()
	if event.is_empty():
		_set_banner_visible(false)
		return
	var key := _alert_key(event)
	if key != _current_alert_key:
		_current_alert_key = key
		_banner_acknowledged = false
	if _banner_acknowledged:
		_set_banner_visible(false)
		return
	var data: Dictionary = event.get("data", {})
	_banner_label.text = _text_table.format(
		"work_table.banner_text", [String(data.get("label", "")), int(data.get("days_until", 0))]
	)
	_set_banner_visible(true)

func _set_banner_visible(is_visible: bool) -> void:
	_banner_label.visible = is_visible
	_banner_button.visible = is_visible
	if not is_visible:
		_banner_label.text = ""

func _dismiss_banner() -> void:
	_banner_acknowledged = true
	refresh()
