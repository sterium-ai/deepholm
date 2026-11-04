extends SceneTree

## F6b-1 evidence (same session pattern as F5c-write-save.gd): writes one real save envelope from a
## deterministic session, through the running build's own StateCodec.encode() and
## SaveIO.write_atomic(). Run from the repo root:
##   godot --headless --path game --script ../docs/orca/handoffs/F6b-1-write-save.gd -- <absolute-output-path>
## On the F6b-1 branch it produced game/scripts/tests/fixtures/save_schema_v15_fixture.json (schema
## v15: animals are entities of kind "animal" in the shared actor table, plus the optional top-level
## "fauna" {nextAnimalId, rng}, ADR 070). On top of whatever mapgen.animal_counts seeds, the session
## spawns a few grasshoppers and two birds on the first surface soil tiles it finds and ticks until
## the fauna stream has been drawn from.

const WorldStateType = preload("res://scripts/core/world_state.gd")
const StateCodecType = preload("res://scripts/core/persistence/state_codec.gd")
const SaveIOType = preload("res://scripts/core/persistence/save_io.gd")

const SEED := 1414
const TICKS := 600

func _init() -> void:
	var args := OS.get_cmdline_user_args()
	if args.is_empty():
		push_error("usage: -- <absolute-output-path>")
		quit(2)
		return
	var world := WorldStateType.new(SEED, 3, 24, 24)
	var placed := 0
	for y in range(24):
		for x in range(24):
			if placed < 8 and world.get_tile(x, y) == "soil":
				world._fauna.spawn("bird" if placed >= 6 else "grasshopper", Vector3i(x, y, 0))
				placed += 1
	for i in TICKS:
		world.tick()
	var state := StateCodecType.encode(world)
	var result := SaveIOType.write_atomic(args[0], state)
	print("F6b-1-write-save: placed=%d animals=%d tick=%d hash=%s result=%s" % [placed,
		world._fauna.get_animals().size(), world.get_tick(), world.state_hash(), result])
	quit(0 if result.get("ok", false) else 1)
