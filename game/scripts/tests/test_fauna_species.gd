extends SceneTree

## F6b-1 (ADR 070): species.json compiles through FaunaSpecies.build() and rejects bad content;
## worldgen seeds mapgen "animal_counts" on surface grass outside the spawn clearing, the same for the
## same seed; the fauna stream never perturbs the world's simulation RNG.

const WorldStateType = preload("res://scripts/core/world_state.gd")

const DAY_TICKS := 2200

var _failed := false

func _init() -> void:
	_check_shipped_species_compile()
	_check_bad_content_is_rejected()
	_check_worldgen_seeds_counts()
	_check_fauna_stream_is_separate()
	if _failed:
		quit(1)
		return
	print("test_fauna_species: PASS")
	quit(0)

func _fail(message: String) -> void:
	push_error(message)
	_failed = true

func _expect(condition: bool, message: String) -> void:
	if not condition:
		_fail(message)

func _species_document() -> Dictionary:
	var world := WorldStateType.new(1)
	return (TestAccess.content(world).document("species") as Dictionary).duplicate(true)

func _build(document: Dictionary, counts: Dictionary = {}) -> Dictionary:
	return FaunaSpecies.build(document, counts, DAY_TICKS, TestAccess.content(WorldStateType.new(1)))

func _expect_error(document: Dictionary, counts: Dictionary, needle: String) -> void:
	var table := _build(document, counts)
	_expect(not table["ok"], "expected a failure containing '%s'" % needle)
	_expect(String(table["message"]).contains(needle), "expected '%s' in '%s'" % [needle, table["message"]])

func _check_shipped_species_compile() -> void:
	var table := _build(_species_document())
	_expect(table["ok"], "the shipped species.json must compile: %s" % table.get("message", ""))
	for id: String in ["grasshopper", "bird", "fox", "rabbit", "deer", "wolf"]:
		_expect((table["species"] as Dictionary).has(id), "species.json must define '%s'" % id)
	_expect(int(table["species"]["wolf"]["starve_ticks"]) == 6 * DAY_TICKS, "wolf starve_days 6 must compile to ticks")
	_expect((table["species"]["bird"]["prey"] as Array) == ["grasshopper"], "the bird hunts grasshoppers")

func _check_bad_content_is_rejected() -> void:
	var document := _species_document()
	document["grass_tiles"] = ["no_such_tile"]
	_expect_error(document, {}, "unknown tile 'no_such_tile'")
	document = _species_document()
	(document["species"] as Array).append((document["species"][0] as Dictionary).duplicate(true))
	_expect_error(document, {}, "duplicate species 'grasshopper'")
	document = _species_document()
	document["species"][1]["diet"]["prey"] = ["dragon"]
	_expect_error(document, {}, "unknown prey 'dragon'")
	_expect_error(_species_document(), {"dragon": 3}, "unknown species 'dragon'")
	_expect_error(_species_document(), {"wolf": 1.5}, "expected an integer")
	_expect_error(_species_document(), {"wolf": -1}, "must be at least 0")

func _seeded(seed_value: int, counts: Dictionary) -> FaunaSystem:
	var world := WorldStateType.new(seed_value)
	return FaunaSystem.new(TestAccess.content(world), DAY_TICKS, world.get_tick, TestAccess.tile_grid(world),
		TestAccess.passability(world).passable_for_faction, seed_value, {"animal_counts": counts}, world.get_spawn_clearing())

func _placement(fauna: FaunaSystem) -> Array:
	var tiles := []
	for animal: Dictionary in fauna.get_animals():
		tiles.append([animal["species"], animal["x"], animal["y"], animal["z"]])
	return tiles

func _check_worldgen_seeds_counts() -> void:
	var counts := {"rabbit": 6, "deer": 3, "wolf": 1}
	var world := WorldStateType.new(424242)
	var clearing := world.get_spawn_clearing()
	var fauna := _seeded(424242, counts)
	for id: String in counts.keys():
		_expect(fauna.count_of(id) == counts[id], "worldgen must place %d %s (placed %d)" % [counts[id], id, fauna.count_of(id)])
	for animal: Dictionary in fauna.get_animals():
		_expect(int(animal["z"]) == TileGrid.SURFACE, "animals live on the surface only")
		_expect(not FaunaSystem._in_clearing(TileGrid.tile_of(animal), clearing), "no animal spawns in the clearing")
		_expect(world.get_tile(int(animal["x"]), int(animal["y"])) == "soil", "animals spawn on grass")
		_expect(animal["kind"] == "animal" and animal["factionId"] == "wildlife", "an animal is a wildlife actor")
	_expect(_placement(_seeded(424242, counts)) == _placement(fauna), "the same seed must place the same animals")
	_expect(_placement(_seeded(424243, counts)) != _placement(fauna), "another seed must place them differently")
	_expect(WorldStateType.new(424242)._fauna.get_animals().is_empty(), "shipped mapgen places no animals by default")

## Spawning and ticking animals leaves the world's simulation stream exactly where it was.
func _check_fauna_stream_is_separate() -> void:
	var plain := WorldStateType.new(5150)
	var wild := WorldStateType.new(5150)
	for i in 12:
		wild._fauna.spawn("grasshopper" if i < 10 else "bird", Vector3i(2 + i, 2, 0))
	for _i in DAY_TICKS:
		plain.tick()
		wild.tick()
	_expect(wild._random.state == plain._random.state, "fauna must not draw from the world's RNG")
	_expect(not wild._fauna.get_animals().is_empty(), "the wild world must still carry animals")
