extends SceneTree

## A4: WorldState's ActorIndex (actor id -> actor, tile -> actors) and ItemTable's tile ->
## ground item ids index. Both are trusted only inside WorldState.tick() and must then
## answer exactly what the linear pass over the roster / items answers; outside a tick
## they must see writes made directly to the roster, an actor's x/y or the item map.
## 1. ActorIndex on its own: find/any_at, added/removed/moved/replaced, end_tick, repeated ids.
## 2. A live colony hauling wood to a stockpile: after every route step inside tick(),
##    both indexes agree with the linear pass for every actor and every item. One
##    colonist starts incomplete, so NeedsSystem.ensure_needs() swaps its roster entry
##    for a rebuilt Dictionary inside the first tick (replaced()).
## 3. Out-of-band writes between ticks (what tests and the viewer's debug scenario do)
##    are seen by _find_colonist()/_colonist_at()/has_item_at() straight away.

const WorldStateType = preload("res://scripts/core/world_state.gd")
const ActorIndexType = preload("res://scripts/core/actors/actor_index.gd")

const SEED := 4404
const SIZE := 24
const TICKS := 300

var _failed := false

func _init() -> void:
	_check_actor_index_unit()
	_check_indexes_match_linear_pass_inside_tick()
	_check_out_of_band_writes_between_ticks()

	if _failed:
		quit(1)
		return
	print("test_actor_index: PASS")
	quit()

func _fail(message: String) -> void:
	push_error(message)
	_failed = true

func _expect(condition: bool, message: String) -> void:
	if not condition:
		_fail(message)

func _actor(actor_id: String, x: int, y: int) -> Dictionary:
	return {"id": actor_id, "kind": "colonist", "x": x, "y": y, "z": 0}

func _check_actor_index_unit() -> void:
	var index := ActorIndexType.new()
	var a := _actor("a", 1, 1)
	var b := _actor("b", 1, 1)
	var c := _actor("c", 4, 2)
	var roster: Array[Dictionary] = [a, b, c]
	_expect(not index.is_trusted(), "a fresh index must not be trusted")
	index.begin_tick(roster)
	_expect(index.is_trusted(), "begin_tick() must trust the index")
	_expect(is_same(index.find(roster, "b"), b), "find() must return the roster's own Dictionary")
	_expect(index.find(roster, "zz").is_empty(), "find() of an unknown id must be {}")
	_expect(index.any_at(roster, Vector3i(1, 1, 0)), "two actors stand on (1,1)")
	_expect(index.any_at(roster, Vector3i(1, 1, 0), "a"), "b still stands on (1,1) when a is excluded")
	_expect(not index.any_at(roster, Vector3i(4, 2, 0), "c"), "only c stands on (4,2)")
	c["x"] = 5
	index.moved(c)
	_expect(not index.any_at(roster, Vector3i(4, 2, 0)) and index.any_at(roster, Vector3i(5, 2, 0)), "moved() must refile c on (5,2)")
	var d := _actor("d", 4, 2)
	roster.append(d)
	index.added(d)
	_expect(is_same(index.find(roster, "d"), d) and index.any_at(roster, Vector3i(4, 2, 0)), "added() must file d")
	index.removed(a)
	roster.erase(a)
	_expect(index.find(roster, "a").is_empty(), "removed() must drop a's id")
	_expect(index.any_at(roster, Vector3i(1, 1, 0)) and not index.any_at(roster, Vector3i(1, 1, 0), "b"), "removed() must unfile a, leaving b")
	var rebuilt := _actor("d", 4, 2)
	index.replaced(d, rebuilt)
	roster[roster.find(d)] = rebuilt
	_expect(is_same(index.find(roster, "d"), rebuilt), "replaced() must map d's id to the rebuilt Dictionary")
	_expect(index.any_at(roster, Vector3i(4, 2, 0)) and not index.any_at(roster, Vector3i(4, 2, 0), "d"), "replaced() must leave exactly one d on (4,2)")
	index.end_tick()
	_expect(not index.is_trusted(), "end_tick() must drop trust")
	b["x"] = 9
	_expect(index.any_at(roster, Vector3i(9, 1, 0)) and not index.any_at(roster, Vector3i(1, 1, 0)), "an untrusted index must scan the roster")
	var twin := _actor("b", 0, 0)
	index.begin_tick([b, twin] as Array[Dictionary])
	_expect(not index.is_trusted(), "a roster that repeats an id must leave the index untrusted")

## Every actor and every ground item, answered both ways.
func _verify(world: WorldStateType, where: String) -> void:
	if not TestAccess.actor_index(world).is_trusted() or not TestAccess.item_ids_at_trusted(world):
		_fail("%s: both indexes must be trusted inside tick()" % where)
		return
	var tiles: Dictionary = {}
	for actor in TestAccess.colonists(world):
		var tile := TileGrid.tile_of(actor)
		tiles[tile] = true
		if not is_same(TestAccess.find_colonist(world, String(actor["id"])), actor):
			_fail("%s: _find_colonist(%s) disagrees with the roster" % [where, actor["id"]])
	for item in TestAccess.item_table(world).items.values():
		tiles[TileGrid.tile_of(item)] = true
	for tile in tiles.keys():
		for probe in [tile, tile + Vector3i(1, 0, 0)]:
			var linear_actor := false
			for actor in TestAccess.colonists(world):
				if int(actor["x"]) == probe.x and int(actor["y"]) == probe.y:
					linear_actor = true
			var linear_item := false
			var linear_wood := 0
			for item in TestAccess.item_table(world).items.values():
				if int(item["x"]) == probe.x and int(item["y"]) == probe.y:
					linear_item = true
					if String(item["kind"]) == "wood":
						linear_wood += int(item["count"])
			if TestAccess.colonist_at(world, probe.x, probe.y) != linear_actor:
				_fail("%s: _colonist_at%s disagrees with the roster" % [where, probe])
			if TestAccess.item_table(world).has_item_at(Vector3i(probe.x, probe.y, 0)) != linear_item:
				_fail("%s: has_item_at%s disagrees with the item map" % [where, probe])
			if TestAccess.item_table(world).get_ground_wood(Vector3i(probe.x, probe.y, 0)) != linear_wood:
				_fail("%s: get_ground_wood%s disagrees with the item map" % [where, probe])
			if TestAccess.is_cell_occupied(world, probe.x, probe.y, "") != (linear_actor or linear_item):
				_fail("%s: _is_cell_occupied%s disagrees" % [where, probe])

func _check_indexes_match_linear_pass_inside_tick() -> void:
	var world := WorldStateType.new(SEED, 10, SIZE, SIZE)
	TestAccess.tile_grid(world).tiles.fill(WorldStateType.TILE_FLOOR)
	TestAccess.object_table(world).objects.clear()
	TestAccess.object_table(world).object_factions.clear()
	var corners := [Vector3i(1, 1, 0), Vector3i(SIZE - 2, 1, 0), Vector3i(1, SIZE - 2, 0), Vector3i(SIZE - 2, SIZE - 2, 0)]
	for i in TestAccess.colonists(world).size():
		var corner: Vector3i = corners[i % corners.size()]
		TestAccess.colonists(world)[i]["x"] = corner.x
		TestAccess.colonists(world)[i]["y"] = corner.y
	TestAccess.colonists(world).append({"id": "colonist_partial", "kind": "colonist", "x": 2, "y": SIZE / 2, "z": 0, "route": null, "work": null})
	var partial: Dictionary = TestAccess.colonists(world).back()
	for i in 12:
		TestAccess.item_table(world).place_new_ground_item("wood", 1 + i % 3, Vector3i(3 + (i * 5) % (SIZE - 6), 2 + (i * 7) % (SIZE - 4), 0))
	var zone := world.apply({"actor": "test", "command_id": "zone", "tick": world.get_tick(), "type": "zone_add",
		"payload": {"x": SIZE / 2 - 1, "y": SIZE / 2 - 1, "z": 0, "width": 3, "height": 3}})
	_expect(bool(zone.get("ok", false)), "zone_add must be accepted")
	var checks := [0]
	TestAccess.toils(world).on_actor_moved = func(actor: Dictionary) -> void:
		TestAccess.actor_index(world).moved(actor)
		_verify(world, "tick %d after %s moved" % [world.get_tick(), actor["id"]])
		checks[0] += 1
	var replacements := [0]
	TestAccess.needs_system(world).on_actor_replaced = func(old: Dictionary, new: Dictionary) -> void:
		TestAccess.actor_index(world).replaced(old, new)
		_expect(TestAccess.actor_index(world).is_trusted(), "ensure_needs() rebuilds inside tick(), where the index is trusted")
		_expect(is_same(TestAccess.find_colonist(world, String(new["id"])), new), "_find_colonist() must return the rebuilt Dictionary")
		replacements[0] += 1
	var start_ids := TestAccess.item_table(world).items.keys()
	for _i in TICKS:
		world.tick()
		if _i == 0:
			_expect(not is_same(TestAccess.colonists(world).back(), partial), "ensure_needs() must have rebuilt the incomplete colonist in tick 1")
			_expect(replacements[0] == 1, "the rebuild must have gone through on_actor_replaced inside tick 1, got %d" % replacements[0])
		_expect(not TestAccess.actor_index(world).is_trusted() and not TestAccess.item_ids_at_trusted(world),
			"both indexes must be untrusted between ticks")
		if _failed:
			return
	_expect(checks[0] >= 50, "the colony must have walked enough to make this meaningful, got %d steps" % checks[0])
	var moved_items := 0
	for item_id in start_ids:
		if not TestAccess.item_table(world).items.has(item_id):
			moved_items += 1
	_expect(moved_items >= 3, "hauls must have picked up and placed items mid-tick, got %d" % moved_items)

func _check_out_of_band_writes_between_ticks() -> void:
	var world := WorldStateType.new(SEED, 10, SIZE, SIZE)
	world.tick()
	var colonist: Dictionary = TestAccess.colonists(world)[0]
	var target := Vector3i((int(colonist["x"]) + 3) % SIZE, (int(colonist["y"]) + 2) % SIZE, 0)
	colonist["x"] = target.x
	colonist["y"] = target.y
	_expect(TestAccess.colonist_at(world, target.x, target.y), "_colonist_at() must see an x/y written between ticks")
	var stranger := {"id": "stranger", "kind": "colonist", "x": 0, "y": 0, "z": 0, "route": null, "work": null}
	TestAccess.colonists(world).append(stranger)
	_expect(is_same(TestAccess.find_colonist(world, "stranger"), stranger), "_find_colonist() must see a roster append between ticks")
	TestAccess.item_table(world).items["item_oob"] = {"id": "item_oob", "x": 2, "y": 3, "z": 0, "kind": "wood", "count": 2}
	_expect(TestAccess.item_table(world).has_item_at(Vector3i(2, 3, 0)), "has_item_at() must see an item written into the map between ticks")
	_expect(TestAccess.item_table(world).get_ground_wood(Vector3i(2, 3, 0)) >= 2, "get_ground_wood() must see an item written into the map between ticks")
