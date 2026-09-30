extends SceneTree

## Builds the default boot world two ways: once by instantiating boot.tscn in
## this headless SceneTree, once by calling Boot.build_default_world()
## directly with no scene (the viewer's default is a real New Game, not the
## DebugScenario -- see boot.gd's own doc comment on
## build_default_world()). Both must reach the same state_hash() after an
## identical fixed tick count, proving the viewer scene adds no hidden state
## or input dependency on top of the function it shares with this test.

const BootType = preload("res://scripts/boot.gd")
const BOOT_SCENE_PATH := "res://scenes/boot.tscn"
const FIXED_TICKS := 30

func _init() -> void:
	var scene_hash := _hash_via_scene()
	var direct_hash := _hash_via_direct_build()

	if scene_hash != direct_hash:
		push_error("test_viewer_hash: hash mismatch scene=%d direct=%d" % [scene_hash, direct_hash])
		quit(1)
		return

	print("test_viewer_hash: PASS (hash=%d)" % scene_hash)
	quit()

func _hash_via_scene() -> int:
	var boot_scene: PackedScene = load(BOOT_SCENE_PATH)
	var boot_node: Node = boot_scene.instantiate()
	root.add_child(boot_node)
	# boot.gd builds `world` in _init(), so it is populated right after
	# instantiate(); _ready() (and the tick driver it creates) has not run
	# yet at this point, which is exactly what keeps this comparison honest.
	var world = boot_node.get("world")
	assert(world != null, "boot.tscn did not expose a built world after instantiate()")
	for i in FIXED_TICKS:
		world.tick()
	var h: int = world.state_hash()
	root.remove_child(boot_node)
	boot_node.free()
	return h

func _hash_via_direct_build() -> int:
	var world = BootType.build_default_world()
	for i in FIXED_TICKS:
		world.tick()
	return world.state_hash()
