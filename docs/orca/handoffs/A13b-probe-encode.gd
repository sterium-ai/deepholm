extends SceneTree

## A13b evidence: the cost of StateCodec.encode() on a 256x256 world, of the ContentRegistry
## rebuild that encode() did on main before A13b, and of a full encode()/decode() round trip
## (test_command_preview.gd's yardstick). Best of 5 in one process. Run from the repo root:
##   godot --headless --path game --script ../docs/orca/handoffs/A13b-probe-encode.gd

const ContentRegistryType = preload("res://scripts/core/content/content_registry.gd")
const WorldStateType = preload("res://scripts/core/world_state.gd")
const StateCodecType = preload("res://scripts/core/persistence/state_codec.gd")

func _init() -> void:
	var world := WorldStateType.new(42, 10, 256, 256)
	var best_encode := 1 << 62
	var best_registry := 1 << 62
	var best_roundtrip := 1 << 62
	for i in 5:
		var t := Time.get_ticks_usec()
		StateCodecType.encode(world)
		best_encode = mini(best_encode, Time.get_ticks_usec() - t)
		t = Time.get_ticks_usec()
		ContentRegistryType.new().version()
		best_registry = mini(best_registry, Time.get_ticks_usec() - t)
		t = Time.get_ticks_usec()
		StateCodecType.decode(StateCodecType.encode(world))
		best_roundtrip = mini(best_roundtrip, Time.get_ticks_usec() - t)
	print("encode_us=%d registry_new_us=%d encode_plus_registry_us=%d encode_decode_us=%d" % [best_encode, best_registry, best_encode + best_registry, best_roundtrip])
	quit()
