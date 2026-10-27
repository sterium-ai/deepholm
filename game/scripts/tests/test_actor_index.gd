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
	return {"id": actor_id, "kind": "colonist", "x": x, "y": y}

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
	_expect(index.any_at(roster, 1, 1), "two actors stand on (1,1)")
	_expect(index.any_at(roster, 1, 1, "a"), "b still stands on (1,1) when a is excluded")
	_expect(not index.any_at(roster, 4, 2, "c"), "only c stands on (4,2)")
	c["x"] = 5
	index.moved(c)
	_expect(not index.any_at(roster, 4, 2) and index.any_at(roster, 5, 2), "moved() must refile c on (5,2)")
	var d := _actor("d", 4, 2)
	roster.append(d)
	index.added(d)
	_expect(is_same(index.find(roster, "d"), d) and index.any_at(roster, 4, 2), "added() must file d")
	index.removed(a)
	roster.erase(a)
	_expect(index.find(roster, "a").is_empty(), "removed() must drop a's id")
	_expect(index.any_at(roster, 1, 1) and not index.any_at(roster, 1, 1, "b"), "removed() must unfile a, leaving b")
	var rebuilt := _actor("d", 4, 2)
	index.replaced(d, rebuilt)
	roster[roster.find(d)] = rebuilt
	_expect(is_same(index.find(roster, "d"), rebuilt), "replaced() must map d's id to the rebuilt Dictionary")
	_expect(index.any_at(roster, 4, 2) and not index.any_at(roster, 4, 2, "d"), "replaced() must leave exactly one d on (4,2)")
	index.end_tick()
	_expect(not index.is_trusted(), "end_tick() must drop trust")
	b["x"] = 9
	_expect(index.any_at(roster, 9, 1) and not index.any_at(roster, 1, 1), "an untrusted index must scan the roster")
	var twin := _actor("b", 0, 0)
	index.begin_tick([b, twin] as Array[Dictionary])
	_expect(not index.is_trusted(), "a roster that repeats an id must leave the index untrusted")

## Every actor and every ground item, answered both ways.
func _verify(world: WorldStateType, where: String) -> void:
	if not world._actor_index.is_trusted() or not world._item_table._ids_at_trusted:
		_fail("%s: both indexes must be trusted inside tick()" % where)
		return
	var tiles: Dictionary = {}
	for actor in world._colonists:
		var tile := Vector2i(int(actor["x"]), int(actor["y"]))
		tiles[tile] = true
		if not is_same(world._find_colonist(String(actor["id"])), actor):
			_fail("%s: _find_colonist(%s) disagrees with the roster" % [where, actor["id"]])
	for item in world._item_table.items.values():
		tiles[Vector2i(int(item["x"]), int(item["y"]))] = true
	for tile in tiles.keys():
		for probe in [tile, tile + Vector2i(1, 0)]:
			var linear_actor := false
			for actor in world._colonists:
				if int(actor["x"]) == probe.x and int(actor["y"]) == probe.y:
					linear_actor = true
			var linear_item := false
			var linear_wood := 0
			for item in world._item_table.items.values():
				if int(item["x"]) == probe.x and int(item["y"]) == probe.y:
					linear_item = true
					if String(item["kind"]) == "wood":
						linear_wood += int(item["count"])
			if world._colonist_at(probe.x, probe.y) != linear_actor:
				_fail("%s: _colonist_at%s disagrees with the roster" % [where, probe])
			if world._item_table.has_item_at(probe.x, probe.y) != linear_item:
				_fail("%s: has_item_at%s disagrees with the item map" % [where, probe])
			if world._item_table.get_ground_wood(probe.x, probe.y) != linear_wood:
				_fail("%s: get_ground_wood%s disagrees with the item map" % [where, probe])
			if world._is_cell_occupied(probe.x, probe.y, "") != (linear_actor or linear_item):
				_fail("%s: _is_cell_occupied%s disagrees" % [where, probe])

func _check_indexes_match_linear_pass_inside_tick() -> void:
	var world := WorldStateType.new(SEED, 10, SIZE, SIZE)
	world._tile_grid.tiles.fill(WorldStateType.TILE_FLOOR)
	world._object_table.objects.clear()
	world._object_table.object_factions.clear()
	var corners := [Vector2i(1, 1), Vector2i(SIZE - 2, 1), Vector2i(1, SIZE - 2), Vector2i(SIZE - 2, SIZE - 2)]
	for i in world._colonists.size():
		var corner: Vector2i = corners[i % corners.size()]
		world._colonists[i]["x"] = corner.x
		world._colonists[i]["y"] = corner.y
	world._colonists.append({"id": "colonist_partial", "kind": "colonist", "x": 2, "y": SIZE / 2, "route": null, "work": null})
	var partial: Dictionary = world._colonists.back()
	for i in 12:
		world._item_table.place_new_ground_item("wood", 1 + i % 3, 3 + (i * 5) % (SIZE - 6), 2 + (i * 7) % (SIZE - 4))
	var zone := world.apply({"actor": "test", "command_id": "zone", "tick": world.get_tick(), "type": "zone_add",
		"payload": {"x": SIZE / 2 - 1, "y": SIZE / 2 - 1, "width": 3, "height": 3}})
	_expect(bool(zone.get("ok", false)), "zone_add must be accepted")
	var checks := [0]
	world._toils.on_actor_moved = func(actor: Dictionary) -> void:
		world._actor_index.moved(actor)
		_verify(world, "tick %d after %s moved" % [world.get_tick(), actor["id"]])
		checks[0] += 1
	var replacements := [0]
	world._needs_system.on_actor_replaced = func(old: Dictionary, new: Dictionary) -> void:
		world._actor_index.replaced(old, new)
		_expect(world._actor_index.is_trusted(), "ensure_needs() rebuilds inside tick(), where the index is trusted")
		_expect(is_same(world._find_colonist(String(new["id"])), new), "_find_colonist() must return the rebuilt Dictionary")
		replacements[0] += 1
	var start_ids := world._item_table.items.keys()
	for _i in TICKS:
		world.tick()
		if _i == 0:
			_expect(not is_same(world._colonists.back(), partial), "ensure_needs() must have rebuilt the incomplete colonist in tick 1")
			_expect(replacements[0] == 1, "the rebuild must have gone through on_actor_replaced inside tick 1, got %d" % replacements[0])
		_expect(not world._actor_index.is_trusted() and not world._item_table._ids_at_trusted,
			"both indexes must be untrusted between ticks")
		if _failed:
			return
	_expect(checks[0] >= 50, "the colony must have walked enough to make this meaningful, got %d steps" % checks[0])
	var moved_items := 0
	for item_id in start_ids:
		if not world._item_table.items.has(item_id):
			moved_items += 1
	_expect(moved_items >= 3, "hauls must have picked up and placed items mid-tick, got %d" % moved_items)

func _check_out_of_band_writes_between_ticks() -> void:
	var world := WorldStateType.new(SEED, 10, SIZE, SIZE)
	world.tick()
	var colonist: Dictionary = world._colonists[0]
	var target := Vector2i((int(colonist["x"]) + 3) % SIZE, (int(colonist["y"]) + 2) % SIZE)
	colonist["x"] = target.x
	colonist["y"] = target.y
	_expect(world._colonist_at(target.x, target.y), "_colonist_at() must see an x/y written between ticks")
	var stranger := {"id": "stranger", "kind": "colonist", "x": 0, "y": 0, "route": null, "work": null}
	world._colonists.append(stranger)
	_expect(is_same(world._find_colonist("stranger"), stranger), "_find_colonist() must see a roster append between ticks")
	world._item_table.items["item_oob"] = {"id": "item_oob", "x": 2, "y": 3, "kind": "wood", "count": 2}
	_expect(world._item_table.has_item_at(2, 3), "has_item_at() must see an item written into the map between ticks")
	_expect(world._item_table.get_ground_wood(2, 3) >= 2, "get_ground_wood() must see an item written into the map between ticks")
