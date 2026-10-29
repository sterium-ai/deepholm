extends RefCounted

## Text for the debug viewer's status labels (need/incident alerts, room
## readout, rejected orders, incident names). Presentation-only: every
## function reads WorldState's existing getters or a command result and
## returns a string; boot.gd decides which label shows it.

const WorldStateType = preload("res://scripts/core/world_state.gd")
const TextTableType = preload("res://scripts/viewer/text_table.gd")

const NEED_UNMET_PREFIX := "need_unmet:"
const NEED_SOURCE_MISSING_PREFIX := "need_source_missing:"

## need_alerts_text()'s incident_started events so far, kept in the event
## log's own order (a later read can return one that sorts earlier), for the
## world whose instance id is _incident_world_id (another world restarts
## them), read up to the world.get_events_since() cursor _incident_cursor.
static var _incident_world_id: int = 0
static var _incident_cursor: int = 0
static var _incident_events: Array[Dictionary] = []

## Standing alert list (colonist-ai.md sections 3.1, 3.8 and 4): every
## colonist currently exposing need_unmet:<kind> or need_source_missing:<kind>
## (WorldState.get_colonist_need_reason()), one line each, id-sorted, followed
## by one line per incident_started event WorldState.get_events_since() has
## returned so far -- an incident is a one-time historical
## fact rather than an ongoing condition, so unlike the need lines above it is
## never dropped once shown, only added to as new incidents fire (A6: the
## events are kept here, so they outlive the event log's bounded retention,
## and a refresh copies only the events past _incident_cursor). The need portion
## is rebuilt from scratch every refresh instead of appended to, so it never
## grows tick over tick and a colonist drops off it the instant
## its reason clears -- the same replace-not-append pattern
## rejected_tiles_text() already uses. Presentation-only: no
## simulation rule lives here, it only reads WorldState's existing getters.
## `snapshot` is this tick's WorldState.get_view_snapshot() (A9); {} takes a fresh one.
static func need_alerts_text(world: WorldStateType, text_table: TextTableType, snapshot: Dictionary = {}) -> String:
	if snapshot.is_empty():
		snapshot = world.get_view_snapshot()
	var lines: Array[String] = []
	var need_reasons: Dictionary = snapshot["need_reasons"]
	var ids: Array = snapshot["ids"]
	var worker: Array = snapshot["worker"]
	# Only the colonists with a reason, id-sorted: not a walk over the whole roster.
	var flagged := PackedStringArray()
	for colonist_id: String in need_reasons:
		var row := ids.find(colonist_id) if String(need_reasons[colonist_id]) != "" else -1
		if row >= 0 and worker[row] == 1:
			flagged.append(colonist_id)
	flagged.sort()
	for colonist_id in flagged:
		var reason := String(need_reasons[colonist_id])
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
		var kind_text := text_table.get_string("status.need.%s" % kind)
		lines.append(text_table.format(label_key, [colonist_id, kind_text]))
	if world.get_instance_id() != _incident_world_id:
		_incident_world_id = world.get_instance_id()
		_incident_cursor = 0
		_incident_events = []
	var stream: Dictionary = world.get_events_since(_incident_cursor, ["incident_started"])
	for event in stream["events"]:
		if String(event.get("type", "")) != "incident_started":
			continue
		_incident_events.insert(_incident_events.bsearch_custom(event, event_log_less, false), event)
	_incident_cursor = int(stream["next"])
	for event in _incident_events:
		lines.append(_incident_started_alert_line(text_table, event))
	return "\n".join(lines)

## WorldState's event-log order: (tick, system_priority, entity_id, sequence).
static func event_log_less(a: Dictionary, b: Dictionary) -> bool:
	if a["tick"] != b["tick"]:
		return a["tick"] < b["tick"]
	if a["system_priority"] != b["system_priority"]:
		return a["system_priority"] < b["system_priority"]
	if a["entity_id"] != b["entity_id"]:
		return a["entity_id"] < b["entity_id"]
	return a["sequence"] < b["sequence"]

static func _incident_started_alert_line(text_table: TextTableType, event: Dictionary) -> String:
	var data: Dictionary = event.get("data", {})
	return text_table.format("status.incident_alert_label", [String(data.get("incident_id", "")), String(data.get("faction", ""))])

## Rooms: presentation-only readout of the last selected tile's room
## (docs/architecture/extension-points.md "Presentation") -- reads
## WorldState.get_room_at() and picks a name, Bedroom over Storeroom over
## plain Room, adding no simulation rule of its own. boot.gd recomputes it
## from the inspected tile on every refresh (tick-driven state changes, a zone
## command, committing a tile rectangle) and after loading another world, so
## the label always reflects live state instead of freezing at whatever it
## last showed -- unlike rejected_tiles_text(), which only ever
## replaces on a fresh command outcome, room membership can change out from
## under an inspected tile with no new command aimed at it at all (an
## overlapping zone_add, a wall breached or resealed elsewhere).
static func room_text(world: WorldStateType, text_table: TextTableType, has_inspected_tile: bool, inspected_tile: Vector2i) -> String:
	if not has_inspected_tile:
		return ""
	var room := world.get_room_at(inspected_tile.x, inspected_tile.y)
	if room.is_empty():
		return ""
	var room_key := "status.room.room"
	if bool(room.get("has_bed", false)):
		room_key = "status.room.bedroom"
	elif bool(room.get("has_stockpile", false)):
		room_key = "status.room.storeroom"
	return text_table.format("status.room_label", [text_table.get_string(room_key), int(room["size"]), int(room["door_count"])])

## Replaces (never appends to) the rejected-tiles block on every commit, so a
## later successful drag clears an earlier rejection instead of accumulating.
static func rejected_tiles_text(text_table: TextTableType, rejected: Array[Dictionary]) -> String:
	var lines: Array[String] = []
	for entry in rejected:
		var tile: Vector2i = entry["tile"]
		var reason_text := text_table.get_string("status.reason.%s" % entry["reason"])
		lines.append(text_table.format("status.rejected_tile_label", [tile.x, tile.y, reason_text]))
	return "\n".join(lines)

## The zone tool draws through the map view's own single zone_add-per-drag path
## (see map_view.gd's zone_add_committed signal) instead of one command per
## tile, since a zone is one command for the whole rectangle. Mirrors
## rejected_tiles_text()'s ok/rejected handling for that path: a
## rejection shows its reason, and a later successful drag clears it.
static func zone_result_text(text_table: TextTableType, result: Dictionary) -> String:
	if result.get("ok", false):
		return ""
	var reason_text := text_table.get_string("status.reason.%s" % result["rejection"]["reason"])
	return text_table.format("status.zone_rejected_label", [reason_text])

## The build tool's own click-to-place path (map_view.gd's build_committed
## signal), mirroring zone_result_text()'s ok/rejected handling.
static func build_result_text(text_table: TextTableType, result: Dictionary) -> String:
	if result.get("ok", false):
		return ""
	return text_table.format("status.build_rejected_label", [rejection_text(text_table, result["rejection"])])

## Player text for a command rejection (ADR 052): the core sends codes and
## values only. "params".detail names the failed rule ("rejection.<detail>",
## filled from the params' named values), "params".remedy a JobQueue remedy
## ("status.remedy.<remedy>"); otherwise the reason alone ("status.reason.<reason>").
static func rejection_text(text_table: TextTableType, rejection: Dictionary) -> String:
	var params: Dictionary = rejection.get("params", {})
	if params.has("detail"):
		return text_table.format_named("rejection.%s" % params["detail"], params)
	if params.has("remedy"):
		return text_table.get_string("status.remedy.%s" % params["remedy"])
	return text_table.get_string("status.reason.%s" % rejection.get("reason", ""))

## Player-facing name of an incident: its "incident.<id>" text-table entry,
## or the id with underscores replaced and the first letter capitalised when
## a content incident has no entry yet.
static func incident_display_name(text_table: TextTableType, incident_id: String) -> String:
	var key := "incident." + incident_id
	if text_table.has_string(key):
		return text_table.get_string(key)
	var words := incident_id.replace("_", " ")
	return words.substr(0, 1).to_upper() + words.substr(1)

static func spawn_incident_text(text_table: TextTableType, display_name: String, result: Dictionary) -> String:
	if result.get("ok", false):
		return text_table.format("status.incident_started", [display_name])
	return text_table.format("status.incident_not_started", [display_name, rejection_text(text_table, result.get("rejection", {}))])
