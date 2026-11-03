extends SceneTree

## F6b-1 (ADR 070): actor_sprites.gd draws the snapshot's "animals" roster. A species with pack
## art (the wolf) gets a sprite; the others a species-coloured placeholder dot; a dead animal
## (gone from the roster) is dropped; without the pack nothing is drawn. The frames are built in
## memory, so the test never depends on the real pack.

const ActorSpritesType = preload("res://scripts/viewer/actor_sprites.gd")

var _failed := false

class FakeWorld:
	extends RefCounted
	var animals: Array = []
	func get_view_snapshot(_detail_ids: Array = []) -> Dictionary:
		return {"ids": [], "worker": [], "hp": [], "kinds": [], "factions": [], "x": [], "y": [],
			"animals": animals.duplicate(true)}

func _init() -> void:
	_check_animals_draw()
	_check_no_pack_draws_nothing()
	if _failed:
		quit(1)
		return
	print("test_fauna_viewer: PASS")
	quit(0)

func _expect(condition: bool, message: String) -> void:
	if not condition:
		push_error(message)
		_failed = true

func _wolf_frames() -> Dictionary:
	var frames := SpriteFrames.new()
	var image := Image.create(16, 16, false, Image.FORMAT_RGBA8)
	for animation: String in ["idle", "walk"]:
		if not frames.has_animation(animation):
			frames.add_animation(animation)
		frames.add_frame(animation, ImageTexture.create_from_image(image))
	return {"wolf": frames}

func _animal(id: String, species: String, x: int) -> Dictionary:
	return {"id": id, "kind": "animal", "species": species, "x": x, "y": 3, "z": 0, "factionId": "wildlife"}

func _check_animals_draw() -> void:
	var actors := ActorSpritesType.new(_wolf_frames())
	var world := FakeWorld.new()
	world.animals = [_animal("animal_1", "wolf", 2), _animal("animal_2", "rabbit", 4), _animal("animal_3", "deer", 6)]
	actors.set_world(world)
	_expect(actors.sprite_for("animal_1") != null, "a wild wolf is drawn with the wolf art")
	_expect(actors.placeholder_for("animal_1") == null, "a wolf with art is not also a dot")
	_expect(actors.placeholder_for("animal_2") == ActorSpritesType.ANIMAL_COLORS["rabbit"], "a rabbit is a rabbit-coloured dot")
	_expect(actors.placeholder_for("animal_3") == ActorSpritesType.ANIMAL_COLORS["deer"], "a deer is a deer-coloured dot")
	world.animals = [_animal("animal_2", "rabbit", 5)]
	actors.refresh()
	_expect(actors.sprite_for("animal_1") == null, "a dead wolf's sprite is dropped")
	_expect(actors.placeholder_for("animal_3") == null, "a dead deer's dot is dropped")
	_expect(actors.placeholder_for("animal_2") != null, "the living rabbit is still drawn")
	actors.free()

func _check_no_pack_draws_nothing() -> void:
	var actors := ActorSpritesType.new()
	var world := FakeWorld.new()
	world.animals = [_animal("animal_1", "wolf", 2), _animal("animal_2", "rabbit", 4)]
	actors.set_world(world)
	_expect(actors.sprite_for("animal_1") == null and actors.placeholder_for("animal_2") == null,
		"without the pack, animals draw nothing (as every actor)")
	actors.free()
