extends Control

## Lists each colonist's id, current job (or idle), its current wait/idle
## reason plus remedy, its three need bars, and its need-layer reason. Every
## field is read directly from WorldState's getters (get_colonists/
## get_assignments/get_jobs/get_colonist_need_reason/get_active_need_job_id);
## nothing here is inferred from position deltas, animation, or inactivity.

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

func setup(world_ref: WorldStateType, text_table: TextTableType) -> void:
	world = world_ref
	_text_table = text_table
	_list = VBoxContainer.new()
	add_child(_list)
	refresh()

func refresh() -> void:
	if world == null or _list == null:
		return
	for child in _list.get_children():
		child.queue_free()
	var colonists: Array[Dictionary] = world.get_colonists()
	colonists.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a["id"] < b["id"])
	for colonist in colonists:
		if _is_recruitable_migrant(colonist):
			var row := HBoxContainer.new()
			var label := Label.new()
			label.text = _line_for(colonist)
			row.add_child(label)
			var recruit_button := Button.new()
			recruit_button.text = "Recruit"
			recruit_button.pressed.connect(_on_recruit_pressed.bind(String(colonist["id"])))
			row.add_child(recruit_button)
			_list.add_child(row)
		else:
			var label := Label.new()
			label.text = _line_for(colonist)
			_list.add_child(label)
	_refresh_trade_offers()

## An allied actor can be recruited only when it has reached the colony's
## immediate perimeter. Proximity is presentation-only; set_faction remains
## the authoritative command and validates the actor/faction ids.
func _is_recruitable_migrant(actor: Dictionary) -> bool:
	if String(actor.get("factionId", "colony")) != "allies":
		return false
	var actor_tile := Vector2i(int(actor["x"]), int(actor["y"]))
	for candidate in world.get_colonists():
		if String(candidate.get("factionId", "colony")) != "colony":
			continue
		var colony_tile := Vector2i(int(candidate["x"]), int(candidate["y"]))
		if max(abs(actor_tile.x - colony_tile.x), abs(actor_tile.y - colony_tile.y)) <= 1:
			return true
	return false

## The Recruit button deliberately uses the existing faction command path;
## there is no presentation-specific recruit command.
func _on_recruit_pressed(actor_id: String) -> void:
	world.apply({
		"actor": "player", "command_id": "viewer_recruit_%s_%d" % [actor_id, world.get_tick()],
		"tick": world.get_tick(), "type": "set_faction",
		"payload": {"target": actor_id, "faction_id": "colony"},
	})
	refresh()

## A trade-offer prompt per outstanding trader visit:
## give_item/want_item are read straight off WorldState.get_pending_trade_offers()
## (state only, extension-points.md's Presentation rule -- no decision made
## here about whether to accept) and the Accept button issues the new
## accept_trade command exactly the way boot.gd's own debug buttons already
## issue world.apply(). Hard-coded English text; unlike every other line
## here, this prompt is not yet routed through the text table.
func _refresh_trade_offers() -> void:
	var offers := world.get_pending_trade_offers()
	offers.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return String(a["trader_id"]) < String(b["trader_id"]))
	for offer in offers:
		var trader_id: String = String(offer["trader_id"])
		var row := HBoxContainer.new()
		var label := Label.new()
		label.text = "Trade offer from %s: gives %s, wants %s" % [trader_id, offer["give_item"], offer["want_item"]]
		row.add_child(label)
		var accept_button := Button.new()
		accept_button.text = "Accept"
		accept_button.pressed.connect(_on_accept_trade_pressed.bind(trader_id))
		row.add_child(accept_button)
		_list.add_child(row)

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

func _line_for(colonist: Dictionary) -> String:
	var status := _status_for(colonist)
	var job_text: String
	if status["idle"]:
		job_text = _text_table.get_string("status.idle")
	else:
		job_text = _text_table.get_string("status.job.%s" % status["job_kind"])
	var line := "%s - %s" % [colonist["id"], job_text]
	var tool_id := String(colonist.get("held_tool", ""))
	if not tool_id.is_empty():
		var tool: Dictionary = world.get_tool_item(tool_id)
		if not tool.is_empty():
			line += "\n  %s" % _text_table.format("status.held_tool_label", [String(tool["kind"])])
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
	var need_reason := String(world.get_colonist_need_reason(colonist["id"]))
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
		var rescue_reason := String(world.get_colonist_rescue_reason(colonist["id"]))
		if rescue_reason.is_empty():
			rescue_reason = "trapped"
		return {"idle": true, "job_kind": "", "reason": rescue_reason,
			"remedy": String(TRAPPED_REASON_REMEDY.get(rescue_reason, "await_rescue"))}
	var need_job_status := _need_job_status_for(colonist)
	if not need_job_status.is_empty():
		return need_job_status

	var colonist_id: String = colonist["id"]
	var assignments: Dictionary = world.get_assignments()
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

	var queued := _queued_jobs()
	if queued.is_empty():
		return {"idle": true, "job_kind": "", "reason": "no_work_queued", "remedy": "await_scenario_orders"}
	queued.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return String(a["id"]) < String(b["id"]))
	for job in queued:
		if not String(job["reason"]).is_empty():
			return {"idle": true, "job_kind": "", "reason": job["reason"], "remedy": job["remedy"]}
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
		job_id = String(world.get_active_need_job_id(colonist["id"]))
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

func _queued_jobs() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for job in world.get_jobs():
		if job["status"] == "queued":
			result.append(job)
	return result

func _find_job(job_id: String) -> Dictionary:
	for job in world.get_jobs():
		if job["id"] == job_id:
			return job
	return {}
