extends SceneTree

## L2 evidence (same session as R14-, A5-, A13b-, A16b-, A7-, F1-, F2- and F3-write-save.gd): writes
## one real save envelope from a short deterministic session, through the running build's own
## StateCodec.encode() and SaveIO.write_atomic(). Run from the repo root:
##   godot --headless --path game --script ../docs/orca/handoffs/L2-write-save.gd -- <absolute-output-path>
## On the L2 branch it produced game/scripts/tests/fixtures/save_schema_v9_fixture.json (schema
## v9: F3's v8 plus map.layerCount 1 and "z": 0 on every tile and x/y record, SaveWire
## encoding). F3's v8 fixture (the same session) must migrate to it exactly. The commands carry
## no "z": the command boundary fills the surface (ADR 045 §6).

const WorldStateType = preload("res://scripts/core/world_state.gd")
const StateCodecType = preload("res://scripts/core/persistence/state_codec.gd")
const SaveIOType = preload("res://scripts/core/persistence/save_io.gd")

const SEED := 1414
const TICKS := 150

func _init() -> void:
	var args := OS.get_cmdline_user_args()
	if args.is_empty():
		push_error("usage: -- <absolute-output-path>")
		quit(2)
		return
	var world := WorldStateType.new(SEED, 3, 24, 24)
	var issued := 0
	for y in range(24):
		for x in range(24):
			if issued >= 6:
				break
			for type in ["chop", "dig"]:
				var result: Dictionary = world.apply({"actor": "player", "command_id": "r14_%d_%d_%s" % [x, y, type],
					"tick": world.get_tick(), "type": type, "payload": {"x": x, "y": y, "priority": 1}})
				if result.get("ok", false):
					issued += 1
					break
	world.apply({"actor": "player", "command_id": "r14_zone", "tick": world.get_tick(), "type": "zone_add",
		"payload": {"x": 10, "y": 10, "width": 2, "height": 2}})
	for i in TICKS:
		world.tick()
	var state := StateCodecType.encode(world)
	var result := SaveIOType.write_atomic(args[0], state)
	print("L2-write-save: issued=%d tick=%d hash=%s result=%s" % [issued, world.get_tick(), world.state_hash(), result])
	quit(0 if result.get("ok", false) else 1)
