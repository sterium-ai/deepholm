class_name WorldSetup
extends RefCounted

## What WorldState._init() reads before it wires its modules (A16b, ADR 057): the content
## startup tables every world needs, and a new world's start fields from one scenarios.json
## entry (the starting roster, the calendar document and the enabled-incident list). Pure data
## with no WorldState reference; a default WorldSetup is the base start (mapgen.json's colonist
## count, calendar.json, every incident). A decoded world is always built from the default.

const ContentTablesType = preload("res://scripts/core/content/content_tables.gd")

## -1 keeps mapgen.json's colonist_count.
var colonist_count: int = -1
## Per-colonist definitions, by roster index ({"labour": {kind: level}}); shorter than the roster
## leaves the rest at actors.json's defaults.
var colonists: Array = []
## {} keeps calendar.json.
var calendar: Dictionary = {}
## Only these incidents.json ids enter the daily draw; [] keeps every incident (a scenario's list
## is never empty: no incidents at all is "incidents_enabled": false).
var enabled_incidents: Array[String] = []

## The start fields of one scenarios.json entry (ContentRegistry already validated and
## cross-checked them); a field the entry omits keeps the base start.
static func from_scenario(scenario: Dictionary) -> WorldSetup:
	var setup := WorldSetup.new()
	if scenario.has("roster"):
		var roster: Dictionary = scenario["roster"]
		setup.colonist_count = roster["count"]
		setup.colonists = roster.get("colonists", [])
	if scenario.has("calendar"):
		setup.calendar = scenario["calendar"]
	if scenario.has("incidents"):
		for incident_id: String in (scenario["incidents"] as Array):
			setup.enabled_incidents.append(incident_id)
	return setup

## mapgen.json as world seeding reads it: a scenario roster replaces colonist_count, which
## sizes the spawn clearing and its food sources (WorldGenerator.place_spawn()).
func seeding_mapgen(mapgen: Dictionary) -> Dictionary:
	var seeded := mapgen.duplicate(true)
	if colonist_count >= 0:
		seeded["colonist_count"] = colonist_count
	return seeded

func calendar_document(content: ContentRegistry) -> Dictionary:
	return calendar if not calendar.is_empty() else content.document("calendar")

## The content tables WorldState._init() checks before building the work engine.
class StartupTables:
	## "" or the fatal startup message: the tool requirements' error first, then the haul entry's.
	var error := ""
	## Job kind -> its tool requirement (ContentTables.tool_requirements()).
	var tool_requirements: Dictionary = {}
	## jobs.json's haul entry.
	var haul: Dictionary = {}

static func startup_tables(content: ContentRegistry) -> StartupTables:
	var tables := StartupTables.new()
	tables.error = ContentTablesType.tool_requirements(content, tables.tool_requirements)
	tables.haul = ContentTablesType.index_by_field(content.list("jobs"), "kind").get("haul", {})
	if tables.error.is_empty() and not (tables.haul.has("priority") and tables.haul.has("retry_base_ticks") and tables.haul.has("retry_cap_ticks")):
		tables.error = "jobs.json's 'haul' entry is missing priority/retry_base_ticks/retry_cap_ticks"
	return tables
