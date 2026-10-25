extends SceneTree

## B1 review evidence (not a test): writes saves to validate against
## docs/architecture/contracts/game-state.schema.json -- a fresh encode, a
## mid-expansion encode (non-empty areaOrders done/created) and the v25 fixture
## of test_save_migration.gd migrated to v26. Then B1-schema-check.py
## validates them (needs the `jsonschema` package):
##   godot --headless --path game --script "$PWD/docs/orca/handoffs/B1-schema-saves.gd" -- <out dir>
##   python docs/orca/handoffs/B1-schema-check.py docs/architecture/contracts/game-state.schema.json <out dir>/*.json

const WorldStateType = preload("res://scripts/core/world_state.gd")
const MigrationTest = preload("res://scripts/tests/test_save_migration.gd")
const SaveMigrationsType = preload("res://scripts/core/persistence/save_migrations.gd")

func _init() -> void:
	var out: String = OS.get_cmdline_user_args()[0]
	var world = WorldStateType.new(42, 10, 128, 128)
	_write(out + "/fresh.json", world.to_save_state())
	var n := 0
	for spec in [["dig", Rect2i(0, 0, 128, 128)], ["chop", Rect2i(0, 0, 128, 64)]]:
		n += 1
		world.apply({"actor": "player", "command_id": "a%d" % n, "tick": world.get_tick(), "type": "area_order",
			"payload": {"order": spec[0], "x": spec[1].position.x, "y": spec[1].position.y, "width": spec[1].size.x, "height": spec[1].size.y}})
	for t in 20:
		world.tick()
	world.apply({"actor": "player", "command_id": "a3", "tick": world.get_tick(), "type": "area_order",
		"payload": {"order": "cancel", "x": 0, "y": 100, "width": 128, "height": 20}})
	for t in 20:
		world.tick()
	var mid: Dictionary = world.to_save_state()
	print("mid: done=%d created=%d" % [(mid["areaOrders"]["list"][0]["done"] as Array).size(), (mid["areaOrders"]["created"] as Array).size()])
	_write(out + "/mid_expansion.json", mid)
	var v25: Dictionary = JSON.parse_string(JSON.stringify(MigrationTest.V25_FIXTURE_STATE))
	preload("res://scripts/core/persistence/save_io.gd")._coerce_ints(v25)
	var migrated := SaveMigrationsType.migrate(v25, 25, 26)
	print("migrated ok=%s" % migrated["ok"])
	_write(out + "/migrated_v25.json", migrated["state"])
	quit(0)

func _write(path: String, state: Dictionary) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(JSON.stringify(state))
	file.close()
