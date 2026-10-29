extends SceneTree

## F1 review evidence (not a test): writes populated farm saves to validate against
## docs/architecture/contracts/game-state.schema.json. A 4x4 farm zone of carrots, a stockpile
## with 16 seeds and 6 colonists (test_farm_zone.gd's scenario) are driven by zone_add commands
## and ticks; a state is captured once the zone shows each stage and once a harvest job is
## live, each written through SaveIO.write_atomic() (SaveWire on disk) and read back with
## SaveIO.read(), so what is validated is the plain state every reader sees. Run from the repo
## root, then validate with B1's checker (needs the `jsonschema` package):
##   godot --headless --path game --script ../docs/orca/handoffs/F1-schema-saves.gd -- <absolute out dir>
##   python -I docs/orca/handoffs/B1-schema-check.py docs/architecture/contracts/game-state.schema.json <out dir>/*.json

const WorldStateType = preload("res://scripts/core/world_state.gd")
const SaveIOType = preload("res://scripts/core/persistence/save_io.gd")
const Scenarios = preload("res://scripts/tests/support/scenarios.gd")

const FARM := Rect2i(4, 4, 4, 4)
const STOCKPILE := Rect2i(12, 4, 8, 8)

func _init() -> void:
	var out: String = OS.get_cmdline_user_args()[0]
	var world := WorldStateType.new(560_001, 10, 24, 24)
	TestAccess.tile_grid(world).tiles.fill(WorldStateType.TILE_FLOOR)
	TestAccess.object_table(world).objects.clear()
	TestAccess.colonists(world).clear()
	var labours := {"mine": 3, "chop": 3, "farm": 3, "haul": 3, "build": 3, "craft": 3, "cook": 3}
	for i in 6:
		TestAccess.colonists(world).append({"id": "colonist_%d" % i, "kind": "colonist", "x": 1, "y": 1 + i,
			"route": null, "work": null, "labourTable": labours})
	for y in range(FARM.position.y, FARM.end.y):
		for x in range(FARM.position.x, FARM.end.x):
			TestAccess.set_tile(world, x, y, WorldStateType.TILE_SOIL)
	Scenarios.add_stock(world, "seed", 16, STOCKPILE.position.x, STOCKPILE.position.y)
	Scenarios.command(world, "stock", "zone_add", {"x": STOCKPILE.position.x, "y": STOCKPILE.position.y,
		"width": STOCKPILE.size.x, "height": STOCKPILE.size.y})
	Scenarios.command(world, "farm", "zone_add", {"x": FARM.position.x, "y": FARM.position.y,
		"width": FARM.size.x, "height": FARM.size.y, "kind": "farm", "crop": "carrot"})
	var wanted := {"planted": "farm-planted", "crop_grown": "farm-crop-grown", "crop_ripe": "farm-crop-ripe"}
	var written: Dictionary = {}
	for _i in 6 * TestAccess.calendar(world).day_length_ticks():
		world.tick()
		var tile := world.get_tile(FARM.position.x, FARM.position.y)
		if wanted.has(tile) and not written.has(tile):
			written[tile] = _write(out, wanted[tile], world)
		if not written.has("harvest") and not Scenarios.jobs_of_kind(world, "harvest").is_empty():
			written["harvest"] = _write(out, "farm-harvest-job", world)
	written["end"] = _write(out, "farm-day-6", world)
	print("F1-schema-saves: %s" % written)
	quit(0 if written.values().all(func(ok: bool) -> bool: return ok) and written.size() == 5 else 1)

## Writes name.json (the state SaveIO.read() returns) into out; true when written and read.
func _write(out: String, name: String, world: WorldStateType) -> bool:
	var save_path := "user://f1-schema-saves-%s.json" % name
	var result := SaveIOType.write_atomic(save_path, world.to_save_state())
	var read := SaveIOType.read(save_path)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(save_path))
	if not (result.get("ok", false) and read.get("ok", false)):
		push_error("%s: %s %s" % [name, result, read])
		return false
	var file := FileAccess.open("%s/%s.json" % [out, name], FileAccess.WRITE)
	file.store_string(JSON.stringify(read["state"], "  "))
	file.close()
	print("%s: tick %d, crops %d, tile %s" % [name, world.get_tick(), (read["state"]["crops"] as Array).size(),
		world.get_tile(FARM.position.x, FARM.position.y)])
	return true
