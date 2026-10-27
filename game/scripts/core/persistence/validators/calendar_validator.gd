class_name CalendarValidator
extends SaveCheck

## Save validation for the calendar and incident continuation state: "calendarAlerts",
## "incidentScheduler".

## world._calendar_alerts_fired's wire shape is {fired: [windowId, ...]}
## (StateCodec._encode_calendar_alerts()), a flat set of calendar window ids
## that have already fired their one-shot alert (ADR 008 consequence 6).
## Window ids come from content/calendar.json, whose own schema
## (game/content/schemas/calendar.schema.json) allows any non-empty string
## -- not the stricter ^[a-z0-9_-]+$ entity/job/item id pattern -- so a valid
## calendar id like "SpringSow" must still validate here.
static func _valid_calendar_alerts(value) -> Dictionary:
	if not (value is Dictionary):
		return _fail("invalid calendarAlerts type")
	var calendar_alerts: Dictionary = value
	var check := _require_fields(calendar_alerts, ["fired"], "calendarAlerts")
	if not check["ok"]:
		return check
	if not (calendar_alerts["fired"] is Array):
		return _fail("invalid calendarAlerts.fired type")
	var seen_ids := {}
	for window_id in (calendar_alerts["fired"] as Array):
		if not (window_id is String) or (window_id as String).is_empty():
			return _fail("invalid calendarAlerts.fired entry")
		if seen_ids.has(window_id):
			return _fail("duplicate calendarAlerts.fired id '%s'" % window_id)
		seen_ids[window_id] = true
	return {"ok": true}

## world._incidents' own continuation state (StateCodec._encode_incident_scheduler(),
## ADR 004 "WorldState's diagnostic hash includes this continuation state"):
## a per-incident-id day when its cooldown next clears, the day the scheduler
## last ran its daily draw, and its own independent RNG stream. Every
## cooldownUntilDay key must reference a currently-declared incidents.json id
## pattern -- like every other id-keyed map in this file -- though (unlike
## toolReservations/toolFetchExcluded) it is never cross-checked against
## content/incidents.json itself: that would require SaveIO to load content,
## which no other check here does either.
static func _valid_incident_scheduler(value) -> Dictionary:
	if not (value is Dictionary):
		return _fail("invalid incidentScheduler type")
	var incident_scheduler: Dictionary = value
	var check := _require_fields(incident_scheduler, ["cooldownUntilDay", "lastProcessedDay", "rng"], "incidentScheduler")
	if not check["ok"]:
		return check
	if not (incident_scheduler["cooldownUntilDay"] is Dictionary):
		return _fail("invalid incidentScheduler.cooldownUntilDay type")
	var cooldown_until_day: Dictionary = incident_scheduler["cooldownUntilDay"]
	for incident_id in cooldown_until_day.keys():
		if not _matches_id_pattern(incident_id):
			return _fail("invalid incidentScheduler.cooldownUntilDay key")
		if not _is_int_min(cooldown_until_day[incident_id], 0):
			return _fail("invalid incidentScheduler.cooldownUntilDay value")
	if not _is_int_min(incident_scheduler["lastProcessedDay"], 0):
		return _fail("invalid incidentScheduler.lastProcessedDay")
	if not (incident_scheduler["rng"] is Dictionary):
		return _fail("invalid incidentScheduler.rng type")
	var rng_check := _require_fields(incident_scheduler["rng"], ["seed", "state"], "incidentScheduler.rng")
	if not rng_check["ok"]:
		return rng_check
	if not _is_int(incident_scheduler["rng"]["seed"]) or not _is_int(incident_scheduler["rng"]["state"]):
		return _fail("invalid incidentScheduler.rng fields")
	return {"ok": true}
