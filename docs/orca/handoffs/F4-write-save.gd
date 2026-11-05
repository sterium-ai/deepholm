extends SceneTree

## F4 evidence (same pattern as F5c-write-save.gd): writes one real save envelope from a
## deterministic session, through the running build's own StateCodec.encode() and
## SaveIO.write_atomic(). Run from the repo root:
##   godot --headless --path game --script ../docs/orca/handoffs/F4-write-save.gd -- <absolute-output-path>
## On the F4 branch it produced game/scripts/tests/fixtures/save_schema_v16_fixture.json (schema
## v16: map.undergroundVersion, ADR 071). The session builds a tunnel with a drill and ticks
## until L1 is discovered, so the fixture carries an underground layer, its veins and the stairs.

const WorldStateType = preload("res://scripts/core/world_state.gd")
const StateCodecType = preload("res://scripts/core/persistence/state_codec.gd")
const SaveIOType = preload("res://scripts/core/persistence/save_io.gd")
const Scenarios = preload("res://scripts/tests/support/scenarios.gd")

const SEED := 4242
const MAX_TICKS := 2000
const TUNNEL := Vector3i(10, 10, 0)

func _init() -> void:
	var args := OS.get_cmdline_user_args()
	if args.is_empty():
		push_error("usage: -- <absolute-output-path>")
		quit(2)
		return
	var world := Scenarios.empty_floor_world(SEED)
	TestAccess.colonists(world).append(Scenarios.idle_colonist("colonist_0", 1, 1))
	Scenarios.command(world, "f4_zone", "zone_add", {"x": 0, "y": 0, "z": 0, "width": 2, "height": 1})
	Scenarios.add_stock(world, "drill", 1, 0, 0)
	Scenarios.add_stock(world, "wood", 2, 1, 0)
	Scenarios.command(world, "f4_tunnel", "build", {"kind": "tunnel", "x": TUNNEL.x, "y": TUNNEL.y, "z": TUNNEL.z})
	while TestAccess.tile_grid(world).layer_count < 2 and world.get_tick() < MAX_TICKS:
		world.tick()
	for i in 20:
		world.tick()
	var state := StateCodecType.encode(world)
	var result := SaveIOType.write_atomic(args[0], state)
	print("F4-write-save: tick=%d layers=%d hash=%s result=%s" % [world.get_tick(), TestAccess.tile_grid(world).layer_count, world.state_hash(), result])
	quit(0 if result.get("ok", false) and TestAccess.tile_grid(world).layer_count >= 2 else 1)
