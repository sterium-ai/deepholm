class_name CalendarValidator
extends SaveCheck

## Save validation for the calendar and incident continuation state: "calendarAlerts",
## "incidentScheduler".

## {fired: [windowId, ...]}, the calendar windows that already fired (ADR 008). Window ids
## are any non-empty string (calendar.schema.json), not the entity id pattern.
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

## IncidentScheduler's continuation (ADR 004): cooldownUntilDay per incident id (id pattern
## only; SaveIO never loads content), last processed day and RNG.
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
