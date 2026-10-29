extends SceneTree

## Covers a scenario's start fields (A16b, ADR 057), through ScenarioBuilder.build() on a pack
## scenario: 1) a 5-colonist roster with its own calendar windows and one enabled incident builds
## headless with a deterministic state_hash(), the same after the same ticks; 2) the roster's
## per-colonist labour definitions land on colonist_0/colonist_1 in the declared key order, the
## rest keep actors.json's defaults; 3) the scenario calendar replaces calendar.json (its boosts
## and its day length); 4) the daily draw spawns only the enabled incident, where the same
## scenario without the list draws others too; 5) every start-field rule the registry enforces
## fails typed, including a roster larger than the spawn clearing, while a roster that fills it
## builds in full; 6) the base scenarios keep mapgen.json's roster and calendar.json; 7) a saved
## and loaded five_camp keeps its calendar and incident list (schema v4) and ticks in step with
## the world that saved it; 8) a recorded five_camp session replays to the same hashes.
## The byte-identity of the default New Game and debug against main is shown by
## docs/orca/handoffs/A16-scenario_dump.gd, not here.

const ContentRegistryType = preload("res://scripts/core/content/content_registry.gd")
const ScenarioBuilderType = preload("res://scripts/core/world/scenario_builder.gd")
const SaveIOType = preload("res://scripts/core/persistence/save_io.gd")
const StateCodecType = preload("res://scripts/core/persistence/state_codec.gd")
const ReplayLogType = preload("res://scripts/core/world/replay_log.gd")
const WorldStateType = preload("res://scripts/core/world_state.gd")
const WorldSetupType = preload("res://scripts/core/world/world_setup.gd")

const BASE := ContentRegistryType.DEFAULT_CONTENT_DIR
const SCHEMAS := ContentRegistryType.DEFAULT_SCHEMA_DIR
const PACK_DIR := "user://test-scenario-start-pack"
const SAVE_PATH := "user://test-scenario-start-save.json"
## The ticks saved before the load: inside day 2, before any incident's min_day (3).
const SAVE_AT_TICK := 150
const TRACE_TICKS := 40
## Twelve scenario days at DAY_LENGTH: past every incidents.json min_day (the latest is 10).
const DAY_LENGTH := 100
const INCIDENT_TICKS := 12 * DAY_LENGTH
const ENABLED_INCIDENT := "trader_visit"

var _failed := false

func _init() -> void:
	var full_clearing := {"id": "full_clearing", "label": "scenario.new_game", "seed": 99, "map": {"width": 48, "height": 48},
		"tick_rate": 10, "incidents_enabled": false, "roster": {"count": _clearing_capacity()}, "setup": []}
	var registry := _registry([_five_camp("five_camp", true), _five_camp("five_camp_all", false), full_clearing])
	_expect(registry != null and registry.is_valid(), "the start-field pack must load: %s" % (registry.get_error() if registry != null else {}))
	if registry != null and registry.is_valid():
		_check_five_colonist_scenario_is_deterministic(registry)
		_check_roster_definitions(registry)
		_check_scenario_calendar(registry)
		_check_only_enabled_incident_draws(registry)
		_check_full_clearing_roster_builds_in_full(registry)
		_check_save_load_keeps_calendar_and_incident_list(registry)
		_check_replay_keeps_calendar_and_incident_list(registry)
	_check_registry_rejects_bad_start_fields()
	_check_base_scenarios_keep_the_base_start()

	if _failed:
		quit(1)
		return
	print("test_scenario_start: PASS")
	quit(0)

func _fail(message: String) -> void:
	push_error(message)
	_failed = true

func _expect(condition: bool, message: String) -> void:
	if not condition:
		_fail(message)

## The acceptance scenario: 5 colonists (two defined), two calendar windows over a 100-tick day,
## and only trader_visit enabled; `restricted` false drops the incident list.
func _five_camp(id: String, restricted: bool) -> Dictionary:
	var scenario := {
		"id": id, "label": "scenario.new_game", "seed": 4242, "map": {"width": 48, "height": 48},
		"tick_rate": 10, "incidents_enabled": true,
		"roster": {"count": 5, "colonists": [{"labour": {"mine": 4, "farm": 0}}, {"labour": {"cook": 1}}]},
		"calendar": {"day_length_ticks": DAY_LENGTH, "windows": [
			{"id": "felling", "labour": "chop", "from": 1, "to": 3, "boost": 2, "label": "calendar.window.sow"},
			{"id": "quarry", "labour": "mine", "from": 2, "to": 4, "boost": 1, "label": "calendar.window.sow"}]},
		"setup": [{"step": "needed_tools"}, {"step": "per_colonist_objects", "kind": "bed"}],
	}
	if restricted:
		scenario["incidents"] = [ENABLED_INCIDENT]
	return scenario

func _check_five_colonist_scenario_is_deterministic(registry: ContentRegistryType) -> void:
	var first := ScenarioBuilderType.build(registry, "five_camp")
	var second := ScenarioBuilderType.build(registry, "five_camp")
	_expect(first.get_colonists().size() == 5, "the roster must spawn 5 colonists, got %d" % first.get_colonists().size())
	var beds := first.get_objects().filter(func(o: Dictionary) -> bool: return o["kind"] == "bed")
	_expect(beds.size() == 5, "per_colonist_objects must follow the scenario roster, got %d beds" % beds.size())
	var worlds: Array[WorldStateType] = [first, second]
	for world in worlds:
		_expect(world.state_hash() == first.state_hash(), "five_camp must hash alike at build time")
	for i in TRACE_TICKS:
		for world in worlds:
			world.tick()
	for world in worlds:
		_expect(world.state_hash() == first.state_hash(), "five_camp must hash alike after %d ticks" % TRACE_TICKS)
	var other := ScenarioBuilderType.build(registry, "five_camp", {"seed": 4243})
	_expect(other.state_hash() != ScenarioBuilderType.build(registry, "five_camp").state_hash(),
		"another seed must build another five_camp")

func _check_roster_definitions(registry: ContentRegistryType) -> void:
	var world := ScenarioBuilderType.build(registry, "five_camp")
	var defaults: Dictionary = {}
	for colonist: Dictionary in ScenarioBuilderType.build(registry, "new_game", {"seed": 4242}).get_colonists():
		defaults = colonist["labourTable"]
	var by_id: Dictionary = {}
	for colonist: Dictionary in world.get_colonists():
		by_id[colonist["id"]] = colonist["labourTable"]
	var expected_0 := defaults.merged({"mine": 4, "farm": 0}, true)
	var expected_1 := defaults.merged({"cook": 1}, true)
	_expect(by_id.get("colonist_0") == expected_0, "colonist_0 must carry its definition, got %s" % by_id.get("colonist_0"))
	_expect(by_id.get("colonist_1") == expected_1, "colonist_1 must carry its definition, got %s" % by_id.get("colonist_1"))
	for id in ["colonist_2", "colonist_3", "colonist_4"]:
		_expect(by_id.get(id) == defaults, "%s must keep the default labour table, got %s" % [id, by_id.get(id)])
	var table_0: Dictionary = by_id.get("colonist_0", {})
	_expect(table_0.keys() == defaults.keys(), "a definition must keep the labour table's key order, got %s" % [table_0.keys()])

func _check_scenario_calendar(registry: ContentRegistryType) -> void:
	var world := ScenarioBuilderType.build(registry, "five_camp", {"incidents_enabled": false})
	_expect(world.get_active_calendar_boost("chop") == 2, "day 1 must carry the felling boost")
	_expect(world.get_active_calendar_boost("mine") == 0, "day 1 must not carry the quarry boost yet")
	_expect(world.get_active_calendar_boost("farm") == 0, "calendar.json's sow window must not apply")
	for i in DAY_LENGTH:
		world.tick()
	# Tick DAY_LENGTH is day 2 only with the scenario's own day length (calendar.json's is 2200).
	_expect(world.get_active_calendar_boost("mine") == 1, "day 2 (tick %d) must carry the quarry boost" % world.get_tick())
	_expect(world.get_active_calendar_boost("chop") == 2, "day 2 must still carry the felling boost")

func _check_only_enabled_incident_draws(registry: ContentRegistryType) -> void:
	var restricted := _drawn_incidents(ScenarioBuilderType.build(registry, "five_camp"))
	var unrestricted := _drawn_incidents(ScenarioBuilderType.build(registry, "five_camp_all"))
	_expect(restricted.has(ENABLED_INCIDENT), "the enabled incident must be drawn, got %s" % [restricted])
	_expect(restricted.all(func(id: String) -> bool: return id == ENABLED_INCIDENT),
		"only the enabled incident may be drawn, got %s" % [restricted])
	_expect(unrestricted.any(func(id: String) -> bool: return id != ENABLED_INCIDENT),
		"without the list the draw must consider other incidents, got %s" % [unrestricted])

func _drawn_incidents(world: WorldStateType) -> Array[String]:
	for i in INCIDENT_TICKS:
		world.tick()
	return _incident_ids(world)

func _incident_ids(world: WorldStateType) -> Array[String]:
	var ids: Array[String] = []
	for event: Dictionary in world.get_events(["incident_started"]):
		var data: Dictionary = event["data"]
		ids.append(data["incident_id"])
	return ids

func _check_registry_rejects_bad_start_fields() -> void:
	var window := {"id": "w", "labour": "chop", "from": 1, "to": 2, "boost": 1, "label": "calendar.window.sow"}
	var cases := [
		[{"roster": {"count": 1, "colonists": [{}, {}]}}, ContentRegistryType.ERROR_SCHEMA_VIOLATION, "more definitions than the roster count"],
		[{"roster": {"count": 1, "colonists": [{"labour": {"dance": 1}}]}}, ContentRegistryType.ERROR_SCHEMA_VIOLATION, "an undeclared labour"],
		[{"roster": {"count": 1, "colonists": [{"labour": {"mine": 9}}]}}, ContentRegistryType.ERROR_SCHEMA_VIOLATION, "a labour level above labour_max"],
		[{"roster": {"count": 1, "colonists": [{"labour": {"mine": "high"}}]}}, ContentRegistryType.ERROR_SCHEMA_VIOLATION, "a non-integer labour level"],
		[{"roster": {"colonists": []}}, ContentRegistryType.ERROR_SCHEMA_VIOLATION, "a roster without a count"],
		[{"roster": {"count": _clearing_capacity() + 1}}, ContentRegistryType.ERROR_SCHEMA_VIOLATION, "a roster larger than the spawn clearing"],
		[{"calendar": {"day_length_ticks": 10, "windows": [window.merged({"labour": "dance"}, true)]}}, ContentRegistryType.ERROR_DANGLING_REFERENCE, "a calendar window naming an unknown labour"],
		[{"calendar": {"day_length_ticks": 10, "windows": [window, window]}}, ContentRegistryType.ERROR_SCHEMA_VIOLATION, "a calendar window listed twice"],
		[{"calendar": {"windows": []}}, ContentRegistryType.ERROR_SCHEMA_VIOLATION, "a calendar without a day length"],
		[{"incidents": ["no_such_incident"]}, ContentRegistryType.ERROR_DANGLING_REFERENCE, "an unknown incident"],
		[{"incidents": [ENABLED_INCIDENT, ENABLED_INCIDENT]}, ContentRegistryType.ERROR_SCHEMA_VIOLATION, "an incident listed twice"],
		[{"incidents": []}, ContentRegistryType.ERROR_SCHEMA_VIOLATION, "an empty incident list"],
	]
	for entry: Array in cases:
		var fields: Dictionary = entry[0]
		var scenario := {"id": "bad", "label": "scenario.new_game", "tick_rate": 10, "incidents_enabled": false, "setup": []}
		var registry := _registry([scenario.merged(fields, true)])
		_expect(not registry.is_valid(), "the registry must reject %s" % entry[2])
		_expect(String(registry.get_error().get("code", "")) == entry[1],
			"%s must fail as %s, got %s" % [entry[2], entry[1], registry.get_error()])

func _check_base_scenarios_keep_the_base_start() -> void:
	var content := ContentRegistryType.new()
	var world := ScenarioBuilderType.build(content, "new_game", {"seed": 42})
	var colonist_count: int = content.document("mapgen")["colonist_count"]
	_expect(world.get_colonists().size() == colonist_count, "new_game must keep mapgen.json's colonist_count")
	_expect(world.get_active_calendar_boost("farm") == 1, "new_game must keep calendar.json's sow window")
	_expect(WorldSetupType.from_scenario(content.get_entry("scenarios", "debug")).enabled_incidents.is_empty(),
		"debug must keep every incident")

## A roster that fills the spawn clearing (mapgen.json's spawn_area_width x spawn_area_height)
## spawns every colonist; one more is rejected at load (see _check_registry_rejects_bad_start_fields()).
func _check_full_clearing_roster_builds_in_full(registry: ContentRegistryType) -> void:
	var world := ScenarioBuilderType.build(registry, "full_clearing")
	_expect(world != null, "a roster that fills the spawn clearing must build")
	if world != null:
		_expect(world.get_colonists().size() == _clearing_capacity(),
			"a %d-colonist roster must spawn %d colonists, got %d" % [_clearing_capacity(), _clearing_capacity(), world.get_colonists().size()])

## Acceptance (review round 1): five_camp saved through SaveIO and loaded back on its session
## registry (as boot.gd does: decode, then enable_incidents()) keeps the scenario's 100-tick day and its one incident, and
## keeps ticking in step with the world that saved it through the twelve days.
func _check_save_load_keeps_calendar_and_incident_list(registry: ContentRegistryType) -> void:
	var world := ScenarioBuilderType.build(registry, "five_camp")
	for i in SAVE_AT_TICK:
		world.tick()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(SAVE_PATH))
	var written := SaveIOType.write_atomic(SAVE_PATH, world.to_save_state(), Callable(), Callable(), registry)
	_expect(written["ok"], "five_camp must save: %s" % written)
	var read := SaveIOType.read(SAVE_PATH, registry)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(SAVE_PATH))
	_expect(read["ok"], "five_camp's save must load: %s" % read)
	if not read["ok"]:
		return
	var state: Dictionary = read["state"]
	var scenario_start: Dictionary = state["scenarioStart"]
	_expect(scenario_start["enabledIncidents"] == [ENABLED_INCIDENT], "the save must hold the incident list, got %s" % [scenario_start])
	var loaded := StateCodecType.decode(state, registry)
	loaded.enable_incidents()
	_expect(loaded.state_hash() == world.state_hash(), "the loaded five_camp must hash like the saved one")
	_expect(loaded.get_active_calendar_boost("mine") == 1, "day 2 (tick %d) must still carry the quarry boost after a load" % loaded.get_tick())
	_expect(loaded.get_active_calendar_boost("farm") == 0, "calendar.json's sow window must not apply after a load")
	for i in INCIDENT_TICKS - SAVE_AT_TICK:
		world.tick()
		loaded.tick()
	_expect(loaded.state_hash() == world.state_hash(), "the loaded five_camp must tick in step with the saved one")
	var drawn := _incident_ids(loaded)
	_expect(drawn.has(ENABLED_INCIDENT) and drawn.all(func(id: String) -> bool: return id == ENABLED_INCIDENT),
		"after a load only the enabled incident may be drawn, got %s" % [drawn])

## A five_camp session recorded with ReplayLog (which starts from a save) and passed through its
## JSON form replays to every checkpoint and the final hash, incidents and calendar included.
func _check_replay_keeps_calendar_and_incident_list(registry: ContentRegistryType) -> void:
	var world := ScenarioBuilderType.build(registry, "five_camp")
	var recorded := ReplayLogType.begin(world, 50, true)
	for i in INCIDENT_TICKS:
		world.tick()
		recorded.observe_tick(world)
	recorded.finish(world)
	_expect(_incident_ids(world).has(ENABLED_INCIDENT), "the recorded session must draw the enabled incident")
	var parsed := ReplayLogType.from_dict(JSON.parse_string(JSON.stringify(recorded.to_dict())), registry)
	_expect(parsed["ok"], "the recorded five_camp log must parse back: %s" % parsed)
	if not parsed["ok"]:
		return
	var replay_log: ReplayLogType = parsed["log"]
	var result := replay_log.replay(Callable(), registry)
	_expect(result["ok"], "the five_camp session must replay to the recorded hashes: %s" % result)

## The spawn clearing's tile count, from mapgen.json.
func _clearing_capacity() -> int:
	var mapgen := ContentRegistryType.new().document("mapgen")
	var clearing_width: int = mapgen["spawn_area_width"]
	var clearing_height: int = mapgen["spawn_area_height"]
	return clearing_width * clearing_height

## A registry over the base bundle plus one pack holding `scenarios`.
func _registry(scenarios: Array) -> ContentRegistryType:
	_cleanup_pack()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(PACK_DIR))
	_write_json(PACK_DIR + "/pack.json", {"id": "scenario_start_pack", "version": "1"})
	_write_json(PACK_DIR + "/scenarios.json", {"scenarios": scenarios})
	var registry := ContentRegistryType.new(BASE, SCHEMAS, [PACK_DIR] as Array[String])
	_cleanup_pack()
	return registry

func _write_json(path: String, value: Dictionary) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(JSON.stringify(value))
	file.close()

func _cleanup_pack() -> void:
	var dir := DirAccess.open(PACK_DIR)
	if dir == null:
		return
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		if not dir.current_is_dir():
			dir.remove(entry)
		entry = dir.get_next()
	dir.list_dir_end()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(PACK_DIR))
