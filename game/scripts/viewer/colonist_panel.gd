extends Control

## Lists each colonist's id, current job (or idle), its current wait/idle
## reason plus remedy, its three need bars, and its need-layer reason. Every
## field is read from WorldState.get_view_snapshot() (A9: its colonists, assignments,
## jobs, need_reasons and need_job_ids, the same values get_colonists()/
## get_assignments()/get_job()/get_colonist_need_reason()/get_active_need_job_id()
## return); nothing here is inferred from position deltas, animation, or inactivity.

const WorldStateType = preload("res://scripts/core/world_state.gd")
const TextTableType = preload("res://scripts/viewer/text_table.gd")

## Job-kind and toil display labels (the panel shows the current toil name
## and reason) are read from data/text/en.json
## via "status.job.%s" and "status.toil.%s", the same TextTableType lookup
## convention the reason/remedy display below already uses.
##
## The toil vocabulary is fixed (ToilExecutor.VOCABULARY: reserve, go_to,
## pick_up, work, place, consume, release_all); reserve/release_all are
## instantaneous bookkeeping around activation/completion, never the
## colonist's *current* toil while a job is active, so only the five
## observable ones have a "status.toil.%s" entry.
##
## The needs layer (colonist-ai.md 3.8 and 4) extends this with each
## colonist's three need bars (food/water/rest, from get_colonists()'s
## "needs" field) and the needs decision layer's own activity/reason
## vocabulary: a committed need job (eat_food/drink_water/sleep) is detected
## the same way an assigned work job is -- by the job id carried on the
## colonist's own route/work field, looked up in get_jobs() -- never by
## comparing colonist position against a source tile. eat_food/drink_water
## have no work phase, so once route and work both go null the job id is no
## longer carried on either field for the single tick spent in the instant
## consume toil; world.get_active_need_job_id() is read as a fallback for
## exactly that case (see _need_job_status_for()), so "Eating"/"Drinking"
## stays visible through the whole job, not just its travel phase. The needs
## layer's live reason (get_colonist_need_reason(): need_unmet:<kind>,
## blocked_source_reserved, blocked_source_unreachable) is shown as a
## separate "need reason" line whenever it is non-empty, independent of
## whatever the primary activity line says, since a colonist can keep
## working its normal job while a need search fails in the background
## (colonist-ai.md 3.1: "the colonist keeps working").

var world: WorldStateType
var _text_table: TextTableType
var _list: VBoxContainer
## A9: rows are kept across refreshes and updated in place. Row key (the colonist
## id, or "t:<trader id>" for a trade offer) -> {"row": Control, "label": Label,
## "button": Button or null}; a row is rebuilt only when it gains or loses its button.
var _rows: Dictionary = {}
## The trade-offer row keys of the last refresh, the recruit buttons it showed, and
## the ids/worker columns its roster was read from.
var _trade_keys: Array[String] = []
var _buttons: Dictionary = {}
var _seen_ids: Array = []
var _seen_worker: Array = []
## A9: on a tick refresh, at most this many colonist lines are recomposed in a window
## that walks the id-sorted roster (_cursor), plus every row on screen (inside the
## enclosing ScrollContainer) and every row that is new or rebuilt. A colony this size
## or smaller gets every line every refresh, as before; in a larger one a row off
## screen is at most ceil(roster / ROWS_PER_REFRESH) ticks old. A refresh at the same
## tick as the last one is not a tick's: it follows a command or a world swap (also
## while paused), so it recomposes every row.
const ROWS_PER_REFRESH := 16
## The id-sorted colonist roster of the last refresh, and where its window starts.
var _roster: PackedStringArray = PackedStringArray()
var _cursor: int = 0
## The tick of the last refresh (-1: none yet).
var _last_tick: int = -1
## The snapshot the line being composed reads.
var _snapshot: Dictionary = {}
## Tool item id -> kind, from _snapshot's tool_items.
var _tool_kinds: Dictionary = {}

func setup(world_ref: WorldStateType, text_table: TextTableType) -> void:
	world = world_ref
	_text_table = text_table
	_list = VBoxContainer.new()
	add_child(_list)
	refresh()

## The colonist ids whose lines the next refresh() recomposes, for
## WorldState.get_view_snapshot(detail_ids): boot.gd asks before taking the tick's
## snapshot, so that one snapshot carries their full records. Every id when the
## world is still at the last refresh's tick; otherwise the window and the rows on screen.
func detail_ids() -> Array:
	if world != null and world.get_tick() == _last_tick:
		return Array(_roster)
	return _window_ids(_visible_ids())

func _window_ids(extra: Array) -> Array:
	var ids: Array = extra.duplicate()
	for k in mini(ROWS_PER_REFRESH, _roster.size()):
		var id := _roster[(_cursor + k) % _roster.size()]
		if not ids.has(id):
			ids.append(id)
	return ids

## The colonist ids whose rows intersect the enclosing ScrollContainer's visible rect;
## [] outside a laid-out scroll view (headless tests, before the first frame). Rows sit
## in roster order, so a binary search finds the first one on screen.
func _visible_ids() -> Array:
	var scroll := _scroll_view()
	if scroll == null or _roster.is_empty() or _list.get_child_count() < _roster.size():
		return []
	var view := scroll.get_global_rect()
	if view.size.y <= 0.0:
		return []
	var low := 0
	var high := _roster.size()
	while low < high:
		var middle := (low + high) / 2
		if (_list.get_child(middle) as Control).get_global_rect().end.y < view.position.y:
			low = middle + 1
		else:
			high = middle
	var ids: Array = []
	for i in range(low, _roster.size()):
		var rect := (_list.get_child(i) as Control).get_global_rect()
		if rect.position.y > view.end.y:
			break
		if rect.size.y > 0.0:
			ids.append(_roster[i])
	return ids

func _scroll_view() -> ScrollContainer:
	if not is_inside_tree():
		return null
	var node := get_parent()
	while node != null and not node is ScrollContainer:
		node = node.get_parent()
	return node as ScrollContainer

## `snapshot` is this tick's WorldState.get_view_snapshot(); {} takes a fresh one.
## Rows are matched by colonist (and trader) id: lines are recomposed for the
## window's rows and for new or rebuilt ones, a label's text is set only when its
## line changed, and rows are added, removed or reordered only when the roster or
## the offers changed. A row whose full record the snapshot lacks is read from one
## extra snapshot of just those ids.
func refresh(snapshot: Dictionary = {}) -> void:
	if world == null or _list == null:
		return
	if snapshot.is_empty():
		snapshot = world.get_view_snapshot(detail_ids())
	# The roster, the recruit buttons and the row order are re-derived only when
	# the actor table or the buttons changed: at 1,000 colonists an ordinary
	# refresh touches only its window's rows.
	var roster_changed := _read_roster(snapshot)
	var buttons := _recruit_buttons(snapshot) if (snapshot["factions"] as Array).has("allies") else {}
	var tick := int(snapshot["tick"])
	var every_row := tick == _last_tick
	var due := {}
	for id in (Array(_roster) if every_row else _window_ids(_visible_ids())):
		due[id] = true
	if roster_changed or buttons != _buttons:
		for colonist_id in _roster:
			var entry: Dictionary = _rows.get(colonist_id, {})
			if entry.is_empty() or (entry["button"] != null) != buttons.has(colonist_id):
				due[colonist_id] = true
	_buttons = buttons
	var details: Dictionary = snapshot["details"]
	var missing: Array = due.keys().filter(func(id: String) -> bool: return not details.has(id))
	var detail_snapshot := snapshot if missing.is_empty() else world.get_view_snapshot(due.keys())
	_use_snapshot(detail_snapshot)
	var rows_created := false
	for colonist_id: String in due:
		rows_created = _sync_row(colonist_id, _compose_line(detail_snapshot["details"][colonist_id]),
			String(buttons.get(colonist_id, "")), _on_recruit_pressed.bind(colonist_id)) or rows_created
	var offers: Array = (snapshot["pending_trade_offers"] as Array).duplicate()
	offers.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return String(a["trader_id"]) < String(b["trader_id"]))
	var trade_keys: Array[String] = []
	for offer: Dictionary in offers:
		var trader_id: String = String(offer["trader_id"])
		var key := "t:" + trader_id
		trade_keys.append(key)
		rows_created = _sync_row(key, _text_table.format("colonists.trade_offer_label", [trader_id, offer["give_item"],
			offer["want_item"]]), _text_table.get_string("colonists.accept_trade"),
			_on_accept_trade_pressed.bind(trader_id)) or rows_created
	if rows_created or roster_changed or trade_keys != _trade_keys:
		var keys: Array[String] = []
		keys.append_array(Array(_roster))
		keys.append_array(trade_keys)
		_drop_rows_not_in(keys)
		for i in keys.size():
			var row: Control = _rows[keys[i]]["row"]
			if row.get_index() != i:
				_list.move_child(row, i)
		_trade_keys = trade_keys
	_use_snapshot({})
	_last_tick = tick
	if not every_row and _roster.size() > ROWS_PER_REFRESH:
		_cursor = (_cursor + ROWS_PER_REFRESH) % _roster.size()

## Drops every row and the roster, so the next refresh() rebuilds them all with
## fresh lines (info_panel.gd calls it when another world is swapped in).
func forget_rows() -> void:
	for key: String in _rows.keys():
		_remove_row(key)
	_roster = PackedStringArray()
	_seen_ids = []
	_seen_worker = []
	_buttons = {}
	_trade_keys = []
	_cursor = 0
	_last_tick = -1

## Re-reads the id-sorted roster when the snapshot's ids or worker columns differ
## from the last ones read; true when they did. A different roster restarts the window.
func _read_roster(snapshot: Dictionary) -> bool:
	var ids: Array = snapshot["ids"]
	var worker: Array = snapshot["worker"]
	if ids == _seen_ids and worker == _seen_worker:
		return false
	_seen_ids = ids
	_seen_worker = worker
	var roster := PackedStringArray()
	for row: int in snapshot["workers_by_id"]:
		roster.append(ids[row])
	if roster != _roster:
		_roster = roster
		_cursor = 0
	return true

## Creates or updates the row `key`: a bare Label, or a Label plus a Button
## (`button_text` non-empty) wired to `on_pressed` when it is created. True when
## the row was (re)created, so refresh() puts it back in order.
func _sync_row(key: String, text: String, button_text: String, on_pressed: Callable) -> bool:
	var created := false
	var entry: Dictionary = _rows.get(key, {})
	if not entry.is_empty() and (entry["button"] != null) != (button_text != ""):
		_remove_row(key)
		entry = {}
	if entry.is_empty():
		var label := Label.new()
		var row: Control = label
		var button: Button = null
		if button_text != "":
			row = HBoxContainer.new()
			row.add_child(label)
			button = Button.new()
			button.pressed.connect(on_pressed)
			row.add_child(button)
		_list.add_child(row)
		entry = {"row": row, "label": label, "button": button}
		_rows[key] = entry
		created = true
	var entry_label: Label = entry["label"]
	if entry_label.text != text:
		entry_label.text = text
	if entry["button"] != null and (entry["button"] as Button).text != button_text:
		(entry["button"] as Button).text = button_text
	return created

func _drop_rows_not_in(keys: Array[String]) -> void:
	var wanted := {}
	for key in keys:
		wanted[key] = true
	for key: String in _rows.keys():
		if not wanted.has(key):
			_remove_row(key)

## Removed from the list at once (not only queued), so get_children() matches the rows.
func _remove_row(key: String) -> void:
	var row: Control = _rows[key]["row"]
	_rows.erase(key)
	_list.remove_child(row)
	row.queue_free()

## colonist id -> Recruit button text, for each recruitable migrant: an allied
## actor can be recruited only when it has reached the colony's immediate
## perimeter (a colony-faction worker within one tile). Proximity is
## presentation-only; set_faction remains the authoritative command and validates
## the actor/faction ids.
func _recruit_buttons(snapshot: Dictionary) -> Dictionary:
	var ids: Array = snapshot["ids"]
	var worker: Array = snapshot["worker"]
	var factions: Array = snapshot["factions"]
	var xs: Array = snapshot["x"]
	var ys: Array = snapshot["y"]
	var colony_tiles := {}
	var allies: Array[int] = []
	for row in ids.size():
		if worker[row] == 0:
			continue
		if factions[row] == "colony":
			colony_tiles[Vector2i(xs[row], ys[row])] = true
		elif factions[row] == "allies":
			allies.append(row)
	var buttons := {}
	for row in allies:
		var tile := Vector2i(xs[row], ys[row])
		for dy in range(-1, 2):
			for dx in range(-1, 2):
				if colony_tiles.has(tile + Vector2i(dx, dy)):
					buttons[ids[row]] = _text_table.get_string("colonists.recruit")
	return buttons

func _use_snapshot(snapshot: Dictionary) -> void:
	_snapshot = snapshot
	_tool_kinds = {}
	for tool_item: Dictionary in snapshot.get("tool_items", []):
		_tool_kinds[String(tool_item["id"])] = String(tool_item["kind"])


## The Recruit button deliberately uses the existing faction command path;
## there is no presentation-specific recruit command.
func _on_recruit_pressed(actor_id: String) -> void:
	world.apply({
		"actor": "player", "command_id": "viewer_recruit_%s_%d" % [actor_id, world.get_tick()],
		"tick": world.get_tick(), "type": "set_faction",
		"payload": {"target": actor_id, "faction_id": "colony"},
	})
	refresh()

## A trade-offer prompt per outstanding trader visit (refresh() lists them after
## the colonists): give_item/want_item are read straight off the snapshot's
## pending_trade_offers (state only, extension-points.md's Presentation rule -- no
## decision made here about whether to accept) and the Accept button issues the
## accept_trade command exactly the way boot.gd's own debug buttons already issue
## world.apply().
## Accept button handler: names only which trader_id the click was for --
## accept_trade itself (WorldState._apply_accept_trade_command()) decides
## whether the trade can go through.
func _on_accept_trade_pressed(trader_id: String) -> void:
	world.apply({
		"actor": "player", "command_id": "viewer_accept_trade_%s_%d" % [trader_id, world.get_tick()],
		"tick": world.get_tick(), "type": "accept_trade", "payload": {"trader_id": trader_id},
	})
	refresh()

## The panel's need bars (colonist-ai.md section 4): the three need kinds
## content/needs.json declares, in a fixed display order, read straight off
## get_colonists()'s "needs" field -- never re-derived from thresholds or
## decay rate, both of which stay core-only.
const NEED_KIND_ORDER: Array[String] = ["food", "water", "rest"]

## Client-side remedy text for the needs layer's own live reason
## (get_colonist_need_reason()), mirroring how _toil_for() below already
## infers display-only state instead of adding a new persisted field:
## WorldState exposes the reason string but no paired remedy for it (unlike
## a queued job's reason/remedy pair), so the remedy shown here is derived
## from the reason, not read from a getter.
##
## need_source_missing:<kind> is handled the same way need_unmet:<kind> is,
## even though the shipped WorldState (see colonist-ai.md's needs-layer
## section) only ever emits need_unmet:<kind> today, for both
## "still searching" and "no source exists at all" -- this panel renders
## whatever string get_colonist_need_reason() returns, so if WorldState is
## ever changed to expose the distinct need_source_missing reason, the panel
## needs no further change to display it correctly.
const NEED_REASON_REMEDY := {
	"blocked_source_reserved": "wait_for_source_release",
	"blocked_source_unreachable": "restore_source_access",
	"need_unmet:food": "provide_food_source",
	"need_unmet:water": "provide_water_source",
	"need_unmet:rest": "provide_bed",
	"need_source_missing:food": "place_food_source",
	"need_source_missing:water": "place_water_source",
	"need_source_missing:rest": "place_bed_source",
}

const TOOL_REASON_REMEDY := {
	"blocked_no_tool": "provide_tool",
	"waiting_for_tool_handover": "wait_for_tool_handover",
}

const TRAPPED_REASON_REMEDY := {
	"trapped": "await_rescue",
	"no_rescuer_available": "await_rescuer",
}

## Tests call this on its own with a get_colonists() entry; it then reads one fresh
## snapshot for the whole line.
func _line_for(colonist: Dictionary) -> String:
	var own_snapshot := _snapshot.is_empty()
	if own_snapshot:
		_use_snapshot(world.get_view_snapshot([String(colonist["id"])]))
	var line := _compose_line(colonist)
	if own_snapshot:
		_use_snapshot({})
	return line

func _compose_line(colonist: Dictionary) -> String:
	var status := _status_for(colonist)
	var job_text: String
	if status["idle"]:
		job_text = _text_table.get_string("status.idle")
	else:
		job_text = _text_table.get_string("status.job.%s" % status["job_kind"])
	var line := "%s - %s" % [colonist["id"], job_text]
	var tool_id := String(colonist.get("held_tool", ""))
	if not tool_id.is_empty():
		if _tool_kinds.has(tool_id):
			line += "\n  %s" % _text_table.format("status.held_tool_label", [String(_tool_kinds[tool_id])])
	var hands_text := _hands_text(colonist)
	if not hands_text.is_empty():
		line += "\n  %s" % _text_table.format("status.hands_label", [hands_text])
	if not status["idle"]:
		var target: Vector2i = status["target"]
		line += "\n  %s" % _text_table.format("status.target_label", [target.x, target.y])
		if status["route_length"] >= 0:
			line += "\n  %s" % _text_table.format("status.route_length_label", [status["route_length"]])
		var toil_text: String = _text_table.get_string("status.toil.%s" % status["toil"])
		line += "\n  %s" % _text_table.format("status.toil_label", [toil_text])
	if not String(status["reason"]).is_empty():
		var reason_text: String = _text_table.get_string("status.reason.%s" % status["reason"])
		var remedy_key := String(TOOL_REASON_REMEDY.get(String(status["reason"]), status["remedy"]))
		var remedy_text: String = _text_table.get_string("status.remedy.%s" % remedy_key)
		line += "\n  %s\n  %s" % [
			_text_table.format("status.reason_label", [reason_text]),
			_text_table.format("status.remedy_label", [remedy_text]),
		]
	for need_line in _need_bar_lines(colonist):
		line += "\n  %s" % need_line
	var need_reason := String((_snapshot["need_reasons"] as Dictionary).get(String(colonist["id"]), ""))
	if not need_reason.is_empty():
		var need_reason_text: String = _text_table.get_string("status.reason.%s" % need_reason)
		var need_remedy_key := String(NEED_REASON_REMEDY.get(need_reason, ""))
		line += "\n  %s" % _text_table.format("status.need_reason_label", [need_reason_text])
		if not need_remedy_key.is_empty():
			var need_remedy_text: String = _text_table.get_string("status.remedy.%s" % need_remedy_key)
			line += "\n  %s" % _text_table.format("status.need_remedy_label", [need_remedy_text])
	return line

## Hands are presentation data supplied by get_colonists(): an ordered list of
## {kind, count} entries. Empty hands intentionally produce no panel line.
func _hands_text(colonist: Dictionary) -> String:
	var entries: Array = colonist.get("hands", [])
	var parts: Array[String] = []
	for entry in entries:
		parts.append("%s x%d" % [String(entry.get("kind", "")), int(entry.get("count", 0))])
	return ", ".join(parts)

## Reads the three need bars directly off get_colonists()'s "needs" field
## (colonist-ai.md section 4), formatted "<Kind>: <value>/<max>"
## with the max the same NEED_FULL every need starts at and restores toward
## (WorldStateType.NEED_FULL), never a hardcoded 100.
func _need_bar_lines(colonist: Dictionary) -> Array[String]:
	var needs: Dictionary = colonist.get("needs", {})
	var lines: Array[String] = []
	for kind in NEED_KIND_ORDER:
		var kind_text: String = _text_table.get_string("status.need.%s" % kind)
		var value := int(needs.get(kind, WorldStateType.NEED_FULL))
		lines.append(_text_table.format("status.need_value_label", [kind_text, value, WorldStateType.NEED_FULL]))
	return lines

## Assigned colonists show their active job's kind. A colonist whose route is
## actively re-routing (colonist-ai.md 3.5/3.8) surfaces reason "rerouting"
## the same way an idle colonist's reason is shown below, even though it is
## not idle. Unassigned colonists are idle; their reason/remedy mirrors the
## highest-priority queued job's own reason/remedy when one is blocked, or an
## honest "no work"/"not yet scheduled" state read from
## get_jobs()/get_assignments() otherwise.
func _status_for(colonist: Dictionary) -> Dictionary:
	if colonist.get("trapped") != null:
		var rescue_reason := String((_snapshot["rescue_reasons"] as Dictionary).get(String(colonist["id"]), ""))
		if rescue_reason.is_empty():
			rescue_reason = "trapped"
		return {"idle": true, "job_kind": "", "reason": rescue_reason,
			"remedy": String(TRAPPED_REASON_REMEDY.get(rescue_reason, "await_rescue"))}
	var need_job_status := _need_job_status_for(colonist)
	if not need_job_status.is_empty():
		return need_job_status

	var colonist_id: String = colonist["id"]
	var assignments: Dictionary = _snapshot["assignments"]
	if assignments.has(colonist_id):
		var job := _find_job(String(assignments[colonist_id]["job_id"]))
		if not job.is_empty() and job["status"] == "active":
			var route_length := -1
			var route = colonist.get("route")
			var reason := String(job.get("reason", ""))
			var remedy := String(job.get("remedy", ""))
			if route != null:
				route_length = route["path"].size() - 1 - int(route["step"])
				if route.get("rerouting") != null:
					reason = "rerouting"
					remedy = "await_new_route"
			return {"idle": false, "job_kind": job["kind"], "toil": _toil_for(colonist, job), "reason": reason, "remedy": remedy,
				"target": job["target"], "route_length": route_length}

	# The lowest-id blocked queued job's reason, summarised by the core
	# without copying every job (B1; get_queued_job_summary()).
	var summary: Dictionary = _snapshot["queued_job_summary"]
	if int(summary["queued"]) == 0:
		return {"idle": true, "job_kind": "", "reason": "no_work_queued", "remedy": "await_scenario_orders"}
	var blocked: Dictionary = summary["first_blocked"]
	if not blocked.is_empty():
		return {"idle": true, "job_kind": "", "reason": blocked["reason"], "remedy": blocked["remedy"]}
	return {"idle": true, "job_kind": "", "reason": "awaiting_scheduling", "remedy": "wait_for_next_tick"}

## A committed need job (colonist-ai.md 3.1/3.4: eat_food/drink_water/sleep)
## is detected exactly the way an assigned work job is above -- by the job id
## the colonist's own route/work field already carries, resolved through
## get_jobs() (WorldState merges need jobs into that same list) -- never by
## comparing the colonist's tile against a source. eat_food/drink_water have
## no `work` phase, so for the single tick between route arrival and the
## instant `consume` toil neither route nor work names the job any more;
## world.get_active_need_job_id() is the fallback for exactly that tick
## (colonist-ai.md 3.8 and its needs-layer section). {} means this colonist is
## not currently pursuing a committed need job (idle, working, or still
## searching for a source with nothing reserved yet); the caller falls back
## to the ordinary work/idle status in that case.
func _need_job_status_for(colonist: Dictionary) -> Dictionary:
	var route = colonist.get("route")
	var work = colonist.get("work")
	var job_id := ""
	if route != null and String(route.get("job_id", "")).begins_with("need_"):
		job_id = String(route["job_id"])
	elif work != null and String(work.get("job_id", "")).begins_with("need_"):
		job_id = String(work["job_id"])
	else:
		job_id = String((_snapshot["need_job_ids"] as Dictionary).get(String(colonist["id"]), ""))
	if job_id.is_empty():
		return {}
	var job := _find_job(job_id)
	if job.is_empty() or job["status"] != "active":
		return {}
	var route_length := -1
	var reason := ""
	var remedy := ""
	if route != null:
		route_length = route["path"].size() - 1 - int(route["step"])
		if route.get("rerouting") != null:
			reason = "rerouting"
			remedy = "await_new_route"
	return {"idle": false, "job_kind": job["kind"], "toil": _toil_for(colonist, job), "reason": reason, "remedy": remedy,
		"target": job["target"], "route_length": route_length}

## The colonist's current toil name, inferred
## from route/work/hands exactly the way WorldState itself branches
## (_advance_colonists for dig/chop, _advance_haul_colonist for haul) rather
## than a new persisted field: dig/chop/forage/sleep only ever drive
## go_to/work; haul drives go_to (twice, once per leg) plus the two instant
## toils pick_up and place, distinguished by whether the colonist's
## hands are empty yet. eat_food/drink_water have no work phase: while
## route is set they are traveling (go_to); once route and work are both null
## the job is in its instant consume toil (WorldState._advance_need_colonist()
## calls _toils.consume() the moment it sees both fields null), reported here
## as "consume" rather than falling into the dig/chop go_to/work branch.
func _toil_for(colonist: Dictionary, job: Dictionary) -> String:
	if String(job["kind"]) == "haul":
		if colonist.get("hands", []).is_empty():
			return "go_to" if colonist.get("route") != null else "pick_up"
		return "go_to" if colonist.get("route") != null else "place"
	if colonist.get("route") == null and colonist.get("work") == null and String(job["kind"]) in ["eat_food", "drink_water"]:
		return "consume"
	return "work" if colonist.get("work") != null else "go_to"

## The snapshot's copy of a job a colonist names (every such job is in it).
func _find_job(job_id: String) -> Dictionary:
	return (_snapshot["jobs"] as Dictionary).get(job_id, {})
