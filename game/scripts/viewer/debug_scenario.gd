extends RefCounted

## The seeded debug-viewer scenario: content/scenarios.json's "debug" entry (A16, ADR 052),
## built by ScenarioBuilder. Its setup places a wall line with a door, chairs and tables, a
## berry bush and a bed around the spawn clearing, submits seeded dig orders, and, only for
## the entry's own seed, tills a starting plot and drops a seed stock. Never reads player/UI
## input, so a scene (boot.tscn) and a scene-free caller (test_viewer_hash.gd) that both call
## build() with the same arguments end up with identical state.

const WorldStateType = preload("res://scripts/core/world_state.gd")
const ContentRegistryType = preload("res://scripts/core/content/content_registry.gd")
const ScenarioBuilderType = preload("res://scripts/core/world/scenario_builder.gd")

const SCENARIO_ID := "debug"

## The base bundle, read once; build() falls back to it when no session registry is given.
static var _base_content: ContentRegistryType

## The entry's own seed and tick rate (scenario_seed() and scenario_tick_rate()) unless given. Any
## other seed builds the same scenario without its farm bootstrap (the "when":
## "scenario_seed" steps), which callers such as test_save_io_atomicity.gd rely on to get a
## still-tick-0 world. incidents_enabled defaults false so tests build byte-identically;
## boot.gd's Debug Scenario button passes true.
static func build(seed_value: Variant = null, tick_rate: Variant = null, incidents_enabled: bool = false,
		content: ContentRegistryType = null) -> WorldStateType:
	var options := {"incidents_enabled": incidents_enabled}
	if seed_value != null:
		options["seed"] = int(seed_value)
	if tick_rate != null:
		options["tick_rate"] = int(tick_rate)
	return ScenarioBuilderType.build(_content(content), SCENARIO_ID, options)

static func scenario_seed() -> int:
	return int(_content(null).get_entry("scenarios", SCENARIO_ID)["seed"])

static func scenario_tick_rate() -> int:
	return int(_content(null).get_entry("scenarios", SCENARIO_ID)["tick_rate"])

## The size of the seed stock the ground_items step drops.
static func starting_seed_count() -> int:
	for step: Dictionary in (_content(null).get_entry("scenarios", SCENARIO_ID)["setup"] as Array):
		if step["step"] == "ground_items":
			return int(step["count"])
	return 0

static func _content(content: ContentRegistryType) -> ContentRegistryType:
	if content != null:
		return content
	if _base_content == null:
		_base_content = ContentRegistryType.new()
	return _base_content
