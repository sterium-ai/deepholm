extends SceneTree

## F5b evidence (same session as R14-, A5-, A13b-, A16b-, A7-, F1-, F2-, F3-, L2- and F6a-write-save.gd): writes
## one real save envelope from a short deterministic session, through the running build's own
## StateCodec.encode() and SaveIO.write_atomic(). Run from the repo root:
##   godot --headless --path game --script ../docs/orca/handoffs/F5b-write-save.gd -- <absolute-output-path>
## On the F5b branch it produced game/scripts/tests/fixtures/save_schema_v12_fixture.json (schema
## v12: "heal" in every colonist's labourTable (3) and skills, ADR 065). Its colonists are seeded
## with heal among their labours, which shifts the other seeded skill levels, so the older fixtures
## (F6a's v11 among them) migrate to heal at zero rather than to this file (as with F3's v8). The commands carry
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
	print("F5b-write-save: issued=%d tick=%d hash=%s result=%s" % [issued, world.get_tick(), world.state_hash(), result])
	quit(0 if result.get("ok", false) else 1)
