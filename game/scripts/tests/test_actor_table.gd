extends SceneTree

## Covers issue #281 (F2 actors and components, docs/architecture/foundation-
## for-breadth.md section F2, docs/decisions/012-actors-and-components.md):
## 1) ActorTable.spawn() against the real content bundle produces a colonist,
##    wolf and trader whose has_component() results exactly match each
##    definition's own declared "components" list in content/actors.json, and
##    the colonist's "worker" component is assembled from its existing
##    labourTable/held_tool fields rather than a new nested key; the wolf's
##    and trader's own spawned health/inventory/combat/wild/visitor state
##    (get_component(), not just has_component()) is proved against their
##    own definitions' tunables, not just declared on paper;
## 2) a fixture bundle whose actors.json names a component outside the known
##    vocabulary fails ContentRegistry construction with typed
##    ERROR_DANGLING_REFERENCE, mirroring jobs.json's is_known_toil() check;
## 3) a fixture bundle whose actors.json gives a tunable a value outside its
##    schema-declared bounds (health.maxHp below its minimum of 1) fails
##    construction with typed ERROR_SCHEMA_VIOLATION;
## 4) a declared component's own validate(tunables) is actually invoked during
##    registry construction (not just the schema's single-field bounds): a
##    component missing its tunables entirely (including needs, whose "rates"
##    Dictionary.get() fallback could otherwise silently accept a missing
##    entry as "zero decay" -- an explicit empty rates Dictionary is still
##    accepted), health.hp above its own maxHp, and worker.labour_default
##    outside [labour_min, labour_max] on either side all fail construction
##    with ERROR_SCHEMA_VIOLATION;
## 5) the schema's closed "components" enum names exactly the vocabulary
##    ActorTable.COMPONENT_NAMES implements, so the two never drift apart;
## 6) ActorNeeds.apply_tick() decays each tracked need by its own declared
##    rate per tick and clamps at zero rather than going negative.

const ContentRegistryType = preload("res://scripts/core/content/content_registry.gd")
const ActorTableType = preload("res://scripts/core/actors/actor_table.gd")
const NeedsType = preload("res://scripts/core/actors/components/needs.gd")
const HealthType = preload("res://scripts/core/actors/components/health.gd")

const ACTORS_SCHEMA_PATH := "res://content/schemas/actors.schema.json"

const UNKNOWN_COMPONENT_FIXTURE_DIR := "user://test-actor-table-fixture-unknown-component"
const OUT_OF_BOUNDS_FIXTURE_DIR := "user://test-actor-table-fixture-out-of-bounds"
const MISSING_TUNABLES_FIXTURE_DIR := "user://test-actor-table-fixture-missing-tunables"
const MISSING_NEEDS_TUNABLES_FIXTURE_DIR := "user://test-actor-table-fixture-missing-needs-tunables"
const EXPLICIT_EMPTY_RATES_FIXTURE_DIR := "user://test-actor-table-fixture-explicit-empty-rates"
const HP_ABOVE_MAXHP_FIXTURE_DIR := "user://test-actor-table-fixture-hp-above-maxhp"
const COLONIST_PARTIAL_HP_FIXTURE_DIR := "user://test-actor-table-fixture-colonist-partial-hp"
const WORKER_DEFAULT_BELOW_MIN_FIXTURE_DIR := "user://test-actor-table-fixture-worker-below-min"
const WORKER_DEFAULT_ABOVE_MAX_FIXTURE_DIR := "user://test-actor-table-fixture-worker-above-max"

## def_id -> the exact components content/actors.json declares for it.
const EXPECTED_COMPONENTS_BY_DEF_ID := {
	"colonist": ["mover", "worker", "needs", "health", "inventory", "combat"],
	"wolf": ["mover", "needs", "health", "combat", "wild"],
	"trader": ["mover", "health", "inventory", "visitor"],
}

var _failed := false

func _init() -> void:
	_check_spawned_components_match_declarations()
	_check_unknown_component_fails_construction()
	_check_out_of_bounds_tunable_fails_construction()
	_check_missing_component_tunables_fails_construction()
	_check_missing_needs_tunables_fails_construction()
	_check_explicit_empty_rates_succeeds_construction()
	_check_hp_above_maxhp_fails_construction()
	_check_colonist_spawns_at_full_health_regardless_of_hp_tunable()
	_check_worker_default_below_min_fails_construction()
	_check_worker_default_above_max_fails_construction()
	_check_schema_vocabulary_matches_implemented_vocabulary()
	_check_needs_apply_tick_behaviour()
	_check_health_apply_tick_behaviour()

	if _failed:
		quit(1)
		return
	print("test_actor_table: PASS")
	quit(0)

func _fail(message: String) -> void:
	push_error(message)
	_failed = true

func _expect(condition: bool, message: String) -> void:
	if not condition:
		_fail(message)

# --- 1) spawn() + has_component()/get_component() against the real bundle --

func _check_spawned_components_match_declarations() -> void:
	var registry := ContentRegistryType.new()
	if not registry.is_valid():
		_fail("the real content bundle must load validly: %s" % registry.get_error())
		return

	for def_id in EXPECTED_COMPONENTS_BY_DEF_ID:
		var declared: Array = EXPECTED_COMPONENTS_BY_DEF_ID[def_id]
		var definition := registry.get_entry("actors", def_id)
		_expect(not definition.is_empty(), "content/actors.json must declare '%s'" % def_id)
		if definition.is_empty():
			continue
		_expect((definition.get("components", []) as Array) == declared,
			"content/actors.json's '%s' must declare exactly %s, got %s"
				% [def_id, declared, definition.get("components")])

		var actor := ActorTableType.spawn(def_id, 1, 2, registry, "%s_test" % def_id)
		_expect(String(actor.get("id", "")) == "%s_test" % def_id, "spawn() must set the given id")
		_expect(String(actor.get("kind", "")) == def_id, "spawn() must set kind to the def_id")
		_expect(int(actor.get("x", -1)) == 1 and int(actor.get("y", -1)) == 2,
			"spawn() must place the actor at the given (x, y)")

		for component_name in ActorTableType.COMPONENT_NAMES:
			var should_have: bool = declared.has(component_name)
			_expect(ActorTableType.has_component(actor, component_name, registry) == should_have,
				"%s's has_component('%s') must be %s" % [def_id, component_name, should_have])

	_check_colonist_shape_is_unchanged(registry)
	_check_wolf_and_trader_component_state(registry)

## Scope-limiting decision (docs/decisions/012-actors-and-components.md),
## updated by issue #283: spawn("colonist", ...) still produces exactly the
## pre-F2 field set for worker's wrapped fields (no new "worker"/"inventory"
## key; get_component(colonist, "worker") still assembles {"labourTable",
## "held_tool"} from those existing fields), but now also carries a real
## "health" field (hp/maxHp/dead), appended last, since health is no longer
## inert for a colonist the way inventory/combat still are. Issue #349/ADR
## 023 adds one more: "needsAccumulator", the sibling of "needs" holding each
## kind's deterministic per-day decay carry, inserted right after "needs"
## (ActorTable._spawn_colonist()'s own literal field order).
func _check_colonist_shape_is_unchanged(registry: ContentRegistryType) -> void:
	var colonist := ActorTableType.spawn("colonist", 3, 4, registry, "colonist_shape_test")
	var expected_keys := ["id", "kind", "x", "y", "needs", "needsAccumulator", "labourTable", "route", "work", "carrying",
		"held_tool", "health"]
	_expect(colonist.keys() == expected_keys,
		"spawn('colonist') must produce exactly the pre-F2 key set/order plus a trailing 'health', got %s" % [colonist.keys()])
	_expect(colonist["held_tool"] == "" and colonist["route"] == null
			and colonist["work"] == null and colonist["carrying"] == null,
		"spawn('colonist') must default route/work/carrying to null and held_tool to ''")

	var colonist_tunables: Dictionary = registry.get_entry("actors", "colonist").get("tunables", {}).get("health", {})
	var expected_max_hp := int(colonist_tunables.get("maxHp", -1))
	_expect(colonist["health"] == {"hp": expected_max_hp, "maxHp": expected_max_hp, "dead": false},
		"spawn('colonist') must build health from content/actors.json's own tunables, got %s" % [colonist["health"]])

	var worker = ActorTableType.get_component(colonist, "worker", registry)
	_expect(worker is Dictionary, "get_component(colonist, 'worker') must return a Dictionary")
	if worker is Dictionary:
		_expect((worker as Dictionary).get("labourTable") == colonist["labourTable"],
			"get_component(colonist, 'worker')['labourTable'] must equal the colonist's own labourTable field")
		_expect((worker as Dictionary).get("held_tool") == colonist["held_tool"],
			"get_component(colonist, 'worker')['held_tool'] must equal the colonist's own held_tool field")

	_expect(ActorTableType.get_component(colonist, "health", registry) == colonist["health"],
		"get_component(colonist, 'health') must equal the colonist's own health field")
	_expect(ActorTableType.get_component(colonist, "combat", registry) == null,
		"get_component() for a component the definition does not declare must be null")

## Proves health/inventory/combat/wild/visitor are actually constructed with
## the spawned actor's own definition's tunables, not just declared on paper
## (has_component() alone reads only the definition, not spawned state).
func _check_wolf_and_trader_component_state(registry: ContentRegistryType) -> void:
	var wolf_def := registry.get_entry("actors", "wolf")
	var wolf_tunables: Dictionary = wolf_def.get("tunables", {})
	var wolf := ActorTableType.spawn("wolf", 5, 6, registry, "wolf_test")

	var wolf_health = ActorTableType.get_component(wolf, "health", registry)
	_expect(wolf_health is Dictionary, "get_component(wolf, 'health') must return a Dictionary")
	if wolf_health is Dictionary:
		var expected_max_hp := int(wolf_tunables.get("health", {}).get("maxHp", -1))
		_expect((wolf_health as Dictionary).get("maxHp") == expected_max_hp,
			"wolf health.maxHp must match its definition's tunables, got %s" % [wolf_health])
		_expect((wolf_health as Dictionary).get("hp") == expected_max_hp,
			"wolf health.hp must default to maxHp, got %s" % [wolf_health])
		_expect((wolf_health as Dictionary).get("dead") == false,
			"wolf health.dead must start false, got %s" % [wolf_health])

	var wolf_combat = ActorTableType.get_component(wolf, "combat", registry)
	_expect(wolf_combat is Dictionary, "get_component(wolf, 'combat') must return a Dictionary")
	if wolf_combat is Dictionary:
		var combat_tunables: Dictionary = wolf_tunables.get("combat", {})
		_expect((wolf_combat as Dictionary).get("attack") == int(combat_tunables.get("attack", -1))
				and (wolf_combat as Dictionary).get("damage") == int(combat_tunables.get("damage", -1))
				and (wolf_combat as Dictionary).get("cooldown") == int(combat_tunables.get("cooldown", -1))
				and (wolf_combat as Dictionary).get("cooldown_remaining") == 0,
			"wolf combat must match its definition's tunables with cooldown_remaining at 0, got %s" % [wolf_combat])

	_expect(ActorTableType.get_component(wolf, "wild", registry) == true,
		"get_component(wolf, 'wild') must be true")

	var trader_def := registry.get_entry("actors", "trader")
	var trader_tunables: Dictionary = trader_def.get("tunables", {})
	var trader := ActorTableType.spawn("trader", 7, 8, registry, "trader_test")

	var trader_health = ActorTableType.get_component(trader, "health", registry)
	_expect(trader_health is Dictionary, "get_component(trader, 'health') must return a Dictionary")
	if trader_health is Dictionary:
		var expected_max_hp := int(trader_tunables.get("health", {}).get("maxHp", -1))
		_expect((trader_health as Dictionary).get("maxHp") == expected_max_hp,
			"trader health.maxHp must match its definition's tunables, got %s" % [trader_health])
		_expect((trader_health as Dictionary).get("hp") == expected_max_hp,
			"trader health.hp must default to maxHp, got %s" % [trader_health])
		_expect((trader_health as Dictionary).get("dead") == false,
			"trader health.dead must start false, got %s" % [trader_health])

	var trader_inventory = ActorTableType.get_component(trader, "inventory", registry)
	_expect(trader_inventory is Dictionary, "get_component(trader, 'inventory') must return a Dictionary")
	if trader_inventory is Dictionary:
		var expected_capacity := int(trader_tunables.get("inventory", {}).get("capacity", -1))
		_expect((trader_inventory as Dictionary).get("items") == [] \
				and (trader_inventory as Dictionary).get("tool") == "" \
				and (trader_inventory as Dictionary).get("capacity") == expected_capacity,
			"trader inventory must start empty with capacity from its definition, got %s" % [trader_inventory])

	_expect(ActorTableType.get_component(trader, "visitor", registry) == true,
		"get_component(trader, 'visitor') must be true")

# --- 2) unknown component name -> ERROR_DANGLING_REFERENCE -----------------

func _check_unknown_component_fails_construction() -> void:
	_write_minimal_bundle(UNKNOWN_COMPONENT_FIXTURE_DIR, {"actors": [
		{"id": "colonist", "components": ["mover", "flight"], "tunables": {"mover": {"speed": 1}}},
	]})
	var registry := ContentRegistryType.new(UNKNOWN_COMPONENT_FIXTURE_DIR, ContentRegistryType.DEFAULT_SCHEMA_DIR)
	_cleanup_dir(UNKNOWN_COMPONENT_FIXTURE_DIR)

	_expect(not registry.is_valid(), "an actors.json naming an unknown component must fail construction")
	var error := registry.get_error()
	_expect(error.get("code") == ContentRegistryType.ERROR_DANGLING_REFERENCE,
		"the fixture's error code must be typed as dangling_reference, got %s" % error)
	_expect(String(error.get("file", "")).ends_with("actors.json"),
		"the fixture's error must name actors.json as the offending file, got %s" % error)

# --- 3) out-of-bounds tunable -> ERROR_SCHEMA_VIOLATION ---------------------

func _check_out_of_bounds_tunable_fails_construction() -> void:
	_write_minimal_bundle(OUT_OF_BOUNDS_FIXTURE_DIR, {"actors": [
		{"id": "colonist", "components": ["health"], "tunables": {"health": {"maxHp": 0}}},
	]})
	var registry := ContentRegistryType.new(OUT_OF_BOUNDS_FIXTURE_DIR, ContentRegistryType.DEFAULT_SCHEMA_DIR)
	_cleanup_dir(OUT_OF_BOUNDS_FIXTURE_DIR)

	_expect(not registry.is_valid(), "an actors.json tunable below its schema minimum must fail construction")
	var error := registry.get_error()
	_expect(error.get("code") == ContentRegistryType.ERROR_SCHEMA_VIOLATION,
		"the fixture's error code must be typed as schema_violation, got %s" % error)
	_expect(String(error.get("file", "")).ends_with("actors.json"),
		"the fixture's error must name actors.json as the offending file, got %s" % error)

# --- 4) component validate() is actually invoked at construction time ------
#
# Each fixture below is schema-valid on its own (every field present passes
# its own single-field bounds check) but violates the declaring component's
# own validate() rule -- a rule the schema's per-field "minimum" checks cannot
# express. If ActorTable.validate_component() were not wired into
# ContentRegistry._init(), every one of these fixtures would construct
# successfully (see the finding this covers).

func _check_missing_component_tunables_fails_construction() -> void:
	_write_minimal_bundle(MISSING_TUNABLES_FIXTURE_DIR, {"actors": [
		{"id": "colonist", "components": ["health"], "tunables": {}},
	]})
	var registry := ContentRegistryType.new(MISSING_TUNABLES_FIXTURE_DIR, ContentRegistryType.DEFAULT_SCHEMA_DIR)
	_cleanup_dir(MISSING_TUNABLES_FIXTURE_DIR)

	_expect(not registry.is_valid(), "a declared component with no matching tunables entry must fail construction")
	var error := registry.get_error()
	_expect(error.get("code") == ContentRegistryType.ERROR_SCHEMA_VIOLATION,
		"the fixture's error code must be typed as schema_violation, got %s" % error)
	_expect(String(error.get("file", "")).ends_with("actors.json"),
		"the fixture's error must name actors.json as the offending file, got %s" % error)

## needs.gd's validate() must require the "rates" key outright: a declared
## needs component with no matching tunables entry at all defaults to {}
## (Dictionary.get()'s fallback), which must not silently pass as "zero
## rates" -- it must fail construction the same way health/worker's missing
## tunables do.
func _check_missing_needs_tunables_fails_construction() -> void:
	_write_minimal_bundle(MISSING_NEEDS_TUNABLES_FIXTURE_DIR, {"actors": [
		{"id": "colonist", "components": ["needs"], "tunables": {}},
	]})
	var registry := ContentRegistryType.new(MISSING_NEEDS_TUNABLES_FIXTURE_DIR, ContentRegistryType.DEFAULT_SCHEMA_DIR)
	_cleanup_dir(MISSING_NEEDS_TUNABLES_FIXTURE_DIR)

	_expect(not registry.is_valid(), "a declared needs component with no matching tunables entry must fail construction")
	var error := registry.get_error()
	_expect(error.get("code") == ContentRegistryType.ERROR_SCHEMA_VIOLATION,
		"the fixture's error code must be typed as schema_violation, got %s" % error)
	_expect(String(error.get("file", "")).ends_with("actors.json"),
		"the fixture's error must name actors.json as the offending file, got %s" % error)

## An explicitly supplied empty rates Dictionary (as opposed to an entirely
## missing tunables entry, above) is a deliberate "no decay" declaration and
## must still construct successfully.
func _check_explicit_empty_rates_succeeds_construction() -> void:
	_write_minimal_bundle(EXPLICIT_EMPTY_RATES_FIXTURE_DIR, {"actors": [
		{"id": "colonist", "components": ["needs"], "tunables": {"needs": {"rates": {}}}},
	]})
	var registry := ContentRegistryType.new(EXPLICIT_EMPTY_RATES_FIXTURE_DIR, ContentRegistryType.DEFAULT_SCHEMA_DIR)
	_cleanup_dir(EXPLICIT_EMPTY_RATES_FIXTURE_DIR)

	_expect(registry.is_valid(), "an explicitly supplied empty rates Dictionary must construct successfully, got %s" % registry.get_error())

func _check_hp_above_maxhp_fails_construction() -> void:
	_write_minimal_bundle(HP_ABOVE_MAXHP_FIXTURE_DIR, {"actors": [
		{"id": "colonist", "components": ["health"], "tunables": {"health": {"maxHp": 10, "hp": 20}}},
	]})
	var registry := ContentRegistryType.new(HP_ABOVE_MAXHP_FIXTURE_DIR, ContentRegistryType.DEFAULT_SCHEMA_DIR)
	_cleanup_dir(HP_ABOVE_MAXHP_FIXTURE_DIR)

	_expect(not registry.is_valid(), "health.hp above health.maxHp must fail construction")
	var error := registry.get_error()
	_expect(error.get("code") == ContentRegistryType.ERROR_SCHEMA_VIOLATION,
		"the fixture's error code must be typed as schema_violation, got %s" % error)
	_expect(String(error.get("file", "")).ends_with("actors.json"),
		"the fixture's error must name actors.json as the offending file, got %s" % error)

## Issue #283 regression: a colonist definition whose health tunables declare
## a valid "hp" below "maxHp" (a value ActorHealth.build() would honor for a
## generic actor) must still spawn a colonist at hp == maxHp, since a
## colonist must always start at full health regardless of that tunable --
## ActorTable._spawn_colonist() must call HealthType.build_full(), not
## HealthType.build().
func _check_colonist_spawns_at_full_health_regardless_of_hp_tunable() -> void:
	_write_minimal_bundle(COLONIST_PARTIAL_HP_FIXTURE_DIR, {"actors": [
		{"id": "colonist", "components": ["health"], "tunables": {"health": {"maxHp": 100, "hp": 10}}},
	]})
	var registry := ContentRegistryType.new(COLONIST_PARTIAL_HP_FIXTURE_DIR, ContentRegistryType.DEFAULT_SCHEMA_DIR)
	_cleanup_dir(COLONIST_PARTIAL_HP_FIXTURE_DIR)

	_expect(registry.is_valid(), "a colonist health.hp below health.maxHp must still construct, got %s" % registry.get_error())
	if not registry.is_valid():
		return
	var colonist := ActorTableType.spawn("colonist", 0, 0, registry, "partial_hp_test")
	_expect(colonist["health"] == {"hp": 100, "maxHp": 100, "dead": false},
		"a spawned colonist must start at hp == maxHp even when content declares a lower 'hp' tunable, got %s" % [colonist["health"]])

func _check_worker_default_below_min_fails_construction() -> void:
	_write_minimal_bundle(WORKER_DEFAULT_BELOW_MIN_FIXTURE_DIR, {"actors": [
		{"id": "colonist", "components": ["worker"],
			"tunables": {"worker": {"labours": ["mine"], "labour_default": 0, "labour_min": 2, "labour_max": 4}}},
	]})
	var registry := ContentRegistryType.new(WORKER_DEFAULT_BELOW_MIN_FIXTURE_DIR, ContentRegistryType.DEFAULT_SCHEMA_DIR)
	_cleanup_dir(WORKER_DEFAULT_BELOW_MIN_FIXTURE_DIR)

	_expect(not registry.is_valid(), "worker.labour_default below labour_min must fail construction")
	var error := registry.get_error()
	_expect(error.get("code") == ContentRegistryType.ERROR_SCHEMA_VIOLATION,
		"the fixture's error code must be typed as schema_violation, got %s" % error)
	_expect(String(error.get("file", "")).ends_with("actors.json"),
		"the fixture's error must name actors.json as the offending file, got %s" % error)

func _check_worker_default_above_max_fails_construction() -> void:
	_write_minimal_bundle(WORKER_DEFAULT_ABOVE_MAX_FIXTURE_DIR, {"actors": [
		{"id": "colonist", "components": ["worker"],
			"tunables": {"worker": {"labours": ["mine"], "labour_default": 5, "labour_min": 0, "labour_max": 4}}},
	]})
	var registry := ContentRegistryType.new(WORKER_DEFAULT_ABOVE_MAX_FIXTURE_DIR, ContentRegistryType.DEFAULT_SCHEMA_DIR)
	_cleanup_dir(WORKER_DEFAULT_ABOVE_MAX_FIXTURE_DIR)

	_expect(not registry.is_valid(), "worker.labour_default above labour_max must fail construction")
	var error := registry.get_error()
	_expect(error.get("code") == ContentRegistryType.ERROR_SCHEMA_VIOLATION,
		"the fixture's error code must be typed as schema_violation, got %s" % error)
	_expect(String(error.get("file", "")).ends_with("actors.json"),
		"the fixture's error must name actors.json as the offending file, got %s" % error)

# --- 5) schema's "components" enum matches ActorTable.COMPONENT_NAMES ------

func _check_schema_vocabulary_matches_implemented_vocabulary() -> void:
	var file := FileAccess.open(ACTORS_SCHEMA_PATH, FileAccess.READ)
	if file == null:
		_fail("could not open %s to check its component enum" % ACTORS_SCHEMA_PATH)
		return
	var schema = JSON.parse_string(file.get_as_text())
	file.close()
	if not (schema is Dictionary):
		_fail("%s did not parse as a JSON object" % ACTORS_SCHEMA_PATH)
		return
	var enum_values: Array = (schema as Dictionary) \
		.get("properties", {}).get("actors", {}).get("items", {}) \
		.get("properties", {}).get("components", {}).get("items", {}) \
		.get("enum", [])
	var declared: Array = enum_values.duplicate()
	declared.sort()
	var implemented: Array = ActorTableType.COMPONENT_NAMES.duplicate()
	implemented.sort()
	_expect(declared == implemented,
		"actors.schema.json's components enum %s must match ActorTable.COMPONENT_NAMES %s" % [declared, implemented])

# --- 6) ActorNeeds.apply_tick() decays via a per-day integer accumulator ---
# (issue #349/ADR 023): each tick adds the kind's rate_per_day (passed in as
# tunables["rates"], unchanged key name) to a running "needsAccumulator"
# carry, and only once that carry reaches tunables["day_length_ticks"] does
# the need actually lose a point, with the remainder kept (never reset).

func _check_needs_apply_tick_behaviour() -> void:
	var actor := {"needs": {"food": 5, "water": 10, "rest": 1}, "needsAccumulator": {"food": 0, "water": 0, "rest": 0}}
	var tunables := {"rates": {"food": 3, "water": 1}, "day_length_ticks": 4}

	NeedsType.apply_tick(actor, tunables)
	_expect(actor["needs"]["food"] == 5 and int(actor["needsAccumulator"]["food"]) == 3,
		"food's accumulator must carry 3/4 without decrementing yet, got %s" % [actor])
	_expect(actor["needs"]["water"] == 10 and int(actor["needsAccumulator"]["water"]) == 1,
		"water's accumulator must carry 1/4 without decrementing yet, got %s" % [actor])
	_expect(actor["needs"]["rest"] == 1, "a need with no declared rate must not decay, got %s" % [actor["needs"]])

	NeedsType.apply_tick(actor, tunables)
	_expect(actor["needs"]["food"] == 4 and int(actor["needsAccumulator"]["food"]) == 2,
		"food's accumulator reaching day_length_ticks must subtract one point and carry the remainder, got %s" % [actor])
	_expect(actor["needs"]["water"] == 10 and int(actor["needsAccumulator"]["water"]) == 2,
		"water must still not have crossed its own threshold, got %s" % [actor])

	for _i in 10:
		NeedsType.apply_tick(actor, tunables)
	_expect(actor["needs"]["food"] == 0, "a need must clamp at zero rather than go negative, got %s" % [actor["needs"]])
	_expect(int(actor["needsAccumulator"]["food"]) >= 0 and int(actor["needsAccumulator"]["food"]) < 4,
		"the accumulator must stay within [0, day_length_ticks) even after the need clamps at 0, got %s" % [actor["needsAccumulator"]])
	# 12 ticks total (2 above + 10 here) at rate 1/tick against day_length_ticks
	# 4 must have crossed the threshold three times (12 / 4 = 3), decrementing
	# water three times from its starting 10 -- proving water keeps decaying
	# past its first threshold crossing, not just carrying a sub-threshold
	# accumulator forever.
	_expect(actor["needs"]["water"] == 7,
		"water must keep decaying past its first threshold crossing, expected 7 after 12 ticks, got %s" % [actor["needs"]])
	_expect(int(actor["needsAccumulator"]["water"]) == 0,
		"water's accumulator must have no remainder after 12 ticks exactly divides day_length_ticks 4, got %s" % [actor["needsAccumulator"]])

	NeedsType.apply_tick(actor, tunables)
	_expect(actor["needs"]["food"] == 0, "a need already at zero must stay at zero, got %s" % [actor["needs"]])

# --- 7) ActorHealth.apply_tick()/clamp() never leave hp outside [0, maxHp] -

func _check_health_apply_tick_behaviour() -> void:
	# A well-formed health value must pass through apply_tick() unchanged --
	# no code path deals damage yet (issue #283 Non-goals).
	var steady := {"health": {"hp": 40, "maxHp": 40, "dead": false}}
	HealthType.apply_tick(steady)
	_expect(steady["health"] == {"hp": 40, "maxHp": 40, "dead": false},
		"apply_tick() must not change a well-formed health value, got %s" % [steady["health"]])

	# hp above maxHp, hp negative, and maxHp itself invalid must all clamp
	# back into bounds under any sequence of apply_tick() calls, with dead
	# tracking hp == 0 exactly.
	var over := {"health": {"hp": 999, "maxHp": 40}}
	HealthType.apply_tick(over)
	_expect(over["health"]["hp"] == 40 and over["health"]["dead"] == false,
		"hp above maxHp must clamp down to maxHp, got %s" % [over["health"]])

	var negative := {"health": {"hp": -5, "maxHp": 40}}
	HealthType.apply_tick(negative)
	_expect(negative["health"]["hp"] == 0 and negative["health"]["dead"] == true,
		"negative hp must clamp to 0 and mark dead, got %s" % [negative["health"]])

	var invalid_max := {"health": {"hp": 0, "maxHp": 0}}
	HealthType.apply_tick(invalid_max)
	_expect(invalid_max["health"]["maxHp"] >= 1 and invalid_max["health"]["hp"] == 0
			and invalid_max["health"]["dead"] == true,
		"maxHp below 1 must floor to 1 and hp must stay clamped, got %s" % [invalid_max["health"]])

	# A dead actor stays dead across repeated ticks -- once hp reaches 0 it
	# never leaves that bound on its own (Non-goals: no healing either).
	HealthType.apply_tick(negative)
	HealthType.apply_tick(negative)
	_expect(negative["health"]["hp"] == 0 and negative["health"]["dead"] == true,
		"a dead actor must stay dead across repeated apply_tick() calls, got %s" % [negative["health"]])

	# Death is permanent, not merely derived from the current hp value: once
	# dead becomes true (hp reached 0), setting hp back to a positive value
	# and re-running apply_tick() must NOT clear dead. A test that only repeats
	# ticks with hp left at 0 (like the block above) cannot tell permanent
	# death apart from "dead == (hp == 0)"; this one distinguishes them.
	var revived := {"health": {"hp": 0, "maxHp": 40, "dead": true}}
	HealthType.apply_tick(revived)
	_expect(revived["health"]["dead"] == true,
		"dead must stay true while hp is still 0, got %s" % [revived["health"]])
	revived["health"]["hp"] = 25
	HealthType.apply_tick(revived)
	_expect(revived["health"]["hp"] == 25 and revived["health"]["dead"] == true,
		"dead must stay true even after hp is set positive again, got %s" % [revived["health"]])
	HealthType.apply_tick(revived)
	HealthType.apply_tick(revived)
	_expect(revived["health"]["dead"] == true,
		"a permanently dead actor must stay dead across further apply_tick() calls, got %s" % [revived["health"]])

	# A missing "health" key (a component the actor's kind doesn't declare)
	# must be a no-op, not an error.
	var no_health := {}
	HealthType.apply_tick(no_health)
	_expect(no_health == {}, "apply_tick() on an actor with no health component must be a no-op")

# --- fixture plumbing (mirrors test_content_registry.gd's own pattern) -----

## Writes an otherwise-valid content bundle (every required kind but actors)
## plus the given actors_content in place of actors.json, so only the actors
## fixture under test can make construction fail. Includes factions.json
## (issue #286, docs/decisions/015-factions-and-relations.md) now that
## "factions" is a required ContentRegistry collection kind like every other.
func _write_minimal_bundle(dir: String, actors_content: Dictionary) -> void:
	var user_dir := DirAccess.open("user://")
	if not user_dir.dir_exists(dir):
		user_dir.make_dir_recursive(dir)

	_write_json(dir + "/manifest.json", {"version": "0.0.1-fixture"})
	_write_json(dir + "/items.json", {"items": [{"id": "axe", "kind": "tool"}]})
	_write_json(dir + "/objects.json", {"objects": [
		{"kind": "bed", "passable": true, "move_cost": 3, "is_door": false, "footprint": [1, 1], "rotatable": false, "build_ticks": 40, "max_builders": 1, "build_cost": []},
	]})
	_write_json(dir + "/needs.json", {"needs": [
		{"kind": "rest", "rate_per_day": 80, "warn": 50, "urgent": 25, "critical": 10, "restore": 100,
			"source_kind": "bed", "full": 100, "job_priority": 1, "retry_base_ticks": 10, "retry_cap_ticks": 40},
	]})
	_write_json(dir + "/calendar.json", {"day_length_ticks": 100, "windows": []})
	_write_json(dir + "/jobs.json", {"jobs": [
		{"kind": "chop", "labour": "chop", "toils": ["reserve", "go_to", "work", "release_all"]},
	]})
	_write_json(dir + "/tiles.json", {"tiles": [
		{"id": "floor", "passable": true, "move_cost": 1, "diggable": false, "display": {"label": "Floor"}, "move_ticks_per_tile": 4},
	]})
	_write_json(dir + "/mapgen.json", {
		"rock_vein_count": 1, "rock_vein_min_length": 1, "rock_vein_max_length": 1,
		"hazard_count": 0, "hazard_placement_attempts": 1,
		"tree_count": 0, "tree_placement_attempts": 1,
		"water_count": 0, "water_placement_attempts": 1,
		"spawn_area_x": 0, "spawn_area_y": 0, "spawn_area_width": 1, "spawn_area_height": 1,
		"colonist_count": 1,
	})
	_write_json(dir + "/factions.json", {"factions": [
		{"id": "colony", "relations": {"wildlife": "neutral"}, "rules": {"may_pass_doors": true, "may_reserve_colony_items": true, "may_be_ordered": true}},
		{"id": "wildlife", "relations": {"colony": "hostile"}, "rules": {"may_pass_doors": false, "may_reserve_colony_items": false, "may_be_ordered": false}},
	]})
	# "incidents" is now a required kind too; every actors_content case in this
	# file declares its actor under id "colonist", so referencing that id here
	# never introduces a second, unrelated dangling-reference failure ahead of
	# whatever this fixture's own actors.json violation is under test.
	_write_json(dir + "/incidents.json", {"incidents": [
		{"id": "test_incident", "faction": "wildlife", "min_day": 1, "weight": 1, "cooldown_days": 1,
			"spawn": {"actor_def": "colonist", "count": 1, "edge": "north", "wait_ticks": 1}},
	]})
	_write_json(dir + "/actors.json", actors_content)

func _write_json(path: String, value: Dictionary) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(JSON.stringify(value))
	file.close()

func _cleanup_dir(dir_path: String) -> void:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		if not dir.current_is_dir():
			dir.remove(entry)
		entry = dir.get_next()
	dir.list_dir_end()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(dir_path))
