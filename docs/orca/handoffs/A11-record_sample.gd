extends SceneTree

## A11 evidence: records a 500-tick session of the default boot world through
## CommandRecorder and writes two replay files for tools/replay.ps1:
##   <out>.json           the recording as made (replays OK)
##   <out>-tampered.json  the same file with checkpoint 300's hash flipped
##                        (replay reports DIVERGED at tick 300, last match 290)
## Usage:
##   godot --headless --path game --script ../docs/orca/handoffs/A11-record_sample.gd -- <out-without-.json>

const BootType = preload("res://scripts/boot.gd")
const WorldStateType = preload("res://scripts/core/world_state.gd")
const CommandRecorderType = preload("res://scripts/viewer/command_recorder.gd")

const TICKS := 500

func _init() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() != 1:
		print("A11-record_sample: usage: -- <out-without-.json>")
		quit(2)
		return
	var out := args[0]
	var world: WorldStateType = BootType.build_default_world()
	var recorder := CommandRecorderType.new()
	recorder.start(world)
	var clearing := world.get_spawn_clearing()
	var cx := int(clearing["x"])
	var cy := int(clearing["y"])
	var n := 0
	while world.get_tick() < TICKS:
		var payloads: Array = []
		match world.get_tick():
			0: payloads = [["set_labour", {"colonist": String(world.get_colonists()[0]["id"]), "kind": "chop", "level": 4}]]
			10: payloads = [["area_order", {"order": "chop", "x": maxi(0, cx - 8), "y": maxi(0, cy - 8), "width": 16, "height": 16}]]
			30: payloads = [["zone_add", {"x": cx, "y": cy, "width": 2, "height": 2}]]
			60: payloads = [["spawn_incident", {"id": "trader_visit"}]]
			150: payloads = [["area_order", {"order": "dig", "x": maxi(0, cx - 6), "y": maxi(0, cy - 6), "width": 12, "height": 12}]]
			250: payloads = [["spawn_incident", {"id": "wildlife_wander"}], ["bogus_type", {}]]
		for entry: Array in payloads:
			n += 1
			var command := {"actor": "player", "command_id": "sample_%d" % n, "tick": world.get_tick(), "type": entry[0], "payload": entry[1]}
			world.apply(command) # heard through world.command_observer, set by start()
		world.tick()
		recorder.observe_tick(world)
	var recording := recorder.stop()
	print("A11-record_sample: %s" % [CommandRecorderType.write_file(recording, out + ".json")])
	for checkpoint in recording.checkpoints:
		if int(checkpoint["tick"]) == 300:
			checkpoint["hash"] = int(checkpoint["hash"]) ^ 1
	print("A11-record_sample: %s" % [CommandRecorderType.write_file(recording, out + "-tampered.json")])
	quit()
