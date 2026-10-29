class_name CalendarValidator
extends SaveCheck

## Save validation for the calendar and incident continuation state: "calendarAlerts",
## "incidentScheduler", "scenarioStart".

const CALENDAR_FIELDS := ["day_length_ticks", "windows"]
const WINDOW_FIELDS := ["id", "labour", "from", "to", "boost", "label"]
## SaveCheck._matches_id_pattern()'s pattern, compiled once for the typed incident-id check.
static var ID_PATTERN := RegEx.create_from_string("^[a-z0-9_-]+$")

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

## The scenario start a world keeps running under (A16b, ADR 057, schema v3): "calendar" is null
## (calendar.json) or a calendar document in calendar.schema.json's shape, window ids unique;
## "enabledIncidents" is a list of distinct incident ids (id pattern only; [] is every incident).
static func _valid_scenario_start(value: Variant) -> Dictionary:
	if not (value is Dictionary):
		return _fail("invalid scenarioStart type")
	var scenario_start: Dictionary = value
	var check := _require_fields(scenario_start, ["calendar", "enabledIncidents"], "scenarioStart")
	if not check["ok"]:
		return check
	var calendar: Variant = scenario_start["calendar"]
	if calendar != null:
		var calendar_check := _valid_calendar_document(calendar)
		if not calendar_check["ok"]:
			return calendar_check
	var enabled: Variant = scenario_start["enabledIncidents"]
	if not (enabled is Array):
		return _fail("invalid scenarioStart.enabledIncidents type")
	var seen_ids := {}
	for incident_id: Variant in (enabled as Array):
		if not (incident_id is String) or not ID_PATTERN.search(incident_id as String):
			return _fail("invalid scenarioStart.enabledIncidents entry")
		if seen_ids.has(incident_id):
			return _fail("duplicate scenarioStart.enabledIncidents id '%s'" % incident_id)
		seen_ids[incident_id] = true
	return {"ok": true}

static func _valid_calendar_document(value: Variant) -> Dictionary:
	if not (value is Dictionary):
		return _fail("invalid scenarioStart.calendar type")
	var calendar: Dictionary = value
	var check := _require_fields(calendar, CALENDAR_FIELDS, "scenarioStart.calendar")
	if not check["ok"]:
		return check
	if not _int_at_least(calendar["day_length_ticks"], 1):
		return _fail("invalid scenarioStart.calendar.day_length_ticks")
	var windows: Variant = calendar["windows"]
	if not (windows is Array):
		return _fail("invalid scenarioStart.calendar.windows type")
	var seen_ids := {}
	for window: Variant in (windows as Array):
		if not (window is Dictionary):
			return _fail("invalid scenarioStart.calendar.windows entry")
		var entry: Dictionary = window
		var window_check := _require_fields(entry, WINDOW_FIELDS, "scenarioStart.calendar window")
		if not window_check["ok"]:
			return window_check
		for field: String in ["id", "labour", "label"]:
			if not (entry[field] is String) or (entry[field] as String).is_empty():
				return _fail("invalid scenarioStart.calendar window %s" % field)
		if not _int_at_least(entry["from"], 1) or not _int_at_least(entry["to"], 1) or not (entry["boost"] is int):
			return _fail("invalid scenarioStart.calendar window range or boost")
		if seen_ids.has(entry["id"]):
			return _fail("duplicate scenarioStart.calendar window id '%s'" % entry["id"])
		seen_ids[entry["id"]] = true
	return {"ok": true}

## A JSON integer (SaveIO already turned whole floats into ints) no smaller than minimum.
static func _int_at_least(value: Variant, minimum: int) -> bool:
	return value is int and (value as int) >= minimum
