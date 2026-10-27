extends SceneTree

## ADR 047 (backlog B5): the persistence bugs the R2/R4 probes found.
## - A rescue's job-scoped work-progress key ("<job_id>:<x>_<y>") must save
##   through SaveIO and load back with the same owner and state_hash; before
##   ADR 047 its workProgressOwners entry was written with an out-of-map tile
##   and SaveIO.write_atomic() refused the whole save.
## - WorkProgress.key_of()/key_parts() are each other's inverse, whatever
##   digits and underscores the job id holds.
## - Two rescues may own timers on the same tile; only a duplicate
##   (ownerJobId, target) pair is invalid.
## - Ground berries change state_hash(), and their factions survive save/load.

const WorldStateType = preload("res://scripts/core/world_state.gd")
const ActorTableType = preload("res://scripts/core/actors/actor_table.gd")
const StateCodecType = preload("res://scripts/core/persistence/state_codec.gd")
const SaveIOType = preload("res://scripts/core/persistence/save_io.gd")
const WorkProgressType = preload("res://scripts/core/jobs/work_progress.gd")

const SAVE_DIR := "user://test-work-progress-persistence"
const TRAP_TICK_BOUND := 40
const RESCUE_TICK_BOUND := 200

var _failed := false

func _init() -> void:
	_check_key_codec_round_trips()
	_check_rescue_mid_work_saves_and_loads_with_identical_hash()
	_check_owner_validation_allows_two_rescues_on_one_tile()
	_check_ground_berries_change_state_hash()
	_check_ground_berry_factions_survive_save_load()

	if _failed:
		quit(1)
		return
	print("test_work_progress_persistence: PASS")
	quit()

func _fail(message: String) -> void:
	push_error(message)
	_failed = true

func _expect(condition: bool, message: String) -> void:
	if not condition:
		_fail(message)

## SaveIO write + read through a real file; {} (after a failed expectation) when either step fails.
func _save_and_read(state: Dictionary, file_name: String) -> Dictionary:
	DirAccess.make_dir_recursive_absolute(SAVE_DIR)
	var path := SAVE_DIR.path_join(file_name)
	var written := SaveIOType.write_atomic(path, state)
	_expect(written.get("ok", false), "SaveIO.write_atomic() must accept the save: %s" % written)
	if not written.get("ok", false):
		return {}
	var read := SaveIOType.read(path)
	_expect(read.get("ok", false), "SaveIO.read() must accept the save it just wrote: %s" % read)
	if not read.get("ok", false):
		return {}
	return read["state"]

## test_rescue.gd's all-floor world with a single colonist ("colonist_0").
func _fresh_world(seed_value: int) -> WorldStateType:
	var world := WorldStateType.new(seed_value)
	world._tile_grid.tiles.fill(WorldStateType.TILE_FLOOR)
	world._object_table.objects.clear()
	world._object_table.object_factions.clear()
	world._colonists.clear()
	world._colonists.append({"id": "colonist_0", "kind": "colonist", "x": 0, "y": 0, "factionId": "colony",
		"needs": {"food": 100, "water": 100, "rest": 100},
		"needsAccumulator": {"food": 0, "water": 0, "rest": 0},
		"labourTable": {"mine": 3, "chop": 3, "farm": 3, "haul": 3, "build": 3, "craft": 3, "cook": 3},
		"route": null, "work": null, "hands": [], "held_tool": "",
		"health": {"hp": 100, "maxHp": 100, "dead": false}})
	return world

func _spawn_colonist(world: WorldStateType, id: String, x: int, y: int) -> Dictionary:
	var colonist: Dictionary = ActorTableType.spawn("colonist", x, y, world._content, id)
	colonist.erase("carrying")
	colonist["hands"] = []
	colonist["factionId"] = "colony"
	world._append_colonist(colonist)
	return colonist

func _check_key_codec_round_trips() -> void:
	for case in [[Vector2i(44, 33), ""], [Vector2i(44, 33), "job_120"], [Vector2i(0, 12), "job_1"],
			[Vector2i(7, 0), "raid_wave-3_9"]]:
		var tile: Vector2i = case[0]
		var scope: String = case[1]
		var key := WorkProgressType.key_of(tile, scope)
		var parts := WorkProgressType.key_parts(key)
		_expect(parts["tile"] == tile and parts["scope"] == scope,
			"key_parts(key_of(%s, '%s')) must give the same tile and scope back, got %s from '%s'" % [tile, scope, parts, key])
	_expect(WorkProgressType.key_of(Vector2i(44, 33), "") == "44_33", "a plain key must stay the tile key")
	_expect(WorkProgressType.key_of(Vector2i(44, 33), "job_120") == "job_120:44_33", "a scoped key must be '<job_id>:<x>_<y>'")

## The R2/R4 probe failure in miniature: a rescue in its own work toil, saved
## through SaveIO, must load back with the same scoped key, the same owner and
## the same state_hash().
func _check_rescue_mid_work_saves_and_loads_with_identical_hash() -> void:
	var world := _fresh_world(450001)
	world._tile_grid.tiles[world._tile_grid.tile_index(1, 0)] = WorldStateType.TILE_TRENCH
	world._tile_grid.tiles[world._tile_grid.tile_index(2, 0)] = WorldStateType.TILE_SOIL
	var victim: Dictionary = world._colonists[0]
	var submit := world._scheduler.submit(Vector2i(2, 0), 1, world.get_tick(), "till", String(victim["id"]))
	_expect(submit.get("ok", false), "setup: till submission must be accepted")
	for _i in TRAP_TICK_BOUND:
		world.tick()
		if victim.get("trapped") != null:
			break
	_expect(victim.get("trapped") != null, "setup: colonist_0 must become trapped")
	var rescuer := _spawn_colonist(world, "colonist_1", 0, 5)
	var scoped_key := ""
	for _i in RESCUE_TICK_BOUND:
		world.tick()
		var work = world._find_colonist(String(rescuer["id"])).get("work")
		if work == null:
			continue
		for key in world._progress_table.progress:
			if String(key).contains(":"):
				scoped_key = String(key)
		if not scoped_key.is_empty():
			break
	_expect(not scoped_key.is_empty(), "setup: the rescue must be mid-work with a job-scoped progress key")
	if scoped_key.is_empty():
		return
	var scope := String(WorkProgressType.key_parts(scoped_key)["scope"])
	_expect(String(world._progress_table.owners.get(scoped_key, "")) == scope, "setup: the rescue must own its scoped key")

	var state := world.to_save_state()
	var owner_entry := {}
	for entry in (state["workProgressOwners"] as Array):
		if String(entry.get("ownerJobId", "")) == scope:
			owner_entry = entry
	_expect(not owner_entry.is_empty(), "the scoped key's owner must be encoded with its ownerJobId")
	var parts := WorkProgressType.key_parts(scoped_key)
	_expect(owner_entry.get("target") == {"x": parts["tile"].x, "y": parts["tile"].y},
		"the owner entry must name the rescue's own target tile, got %s" % [owner_entry.get("target")])

	var read_state := _save_and_read(state, "rescue_mid_work.json")
	if read_state.is_empty():
		return
	var loaded: WorldStateType = WorldStateType.from_save_state(read_state)
	_expect(loaded._progress_table.progress == world._progress_table.progress, "the loaded progress map must be identical")
	_expect(loaded._progress_table.owners == world._progress_table.owners, "the loaded owners must be identical")
	_expect(loaded.state_hash() == world.state_hash(), "a rescue saved mid-work must load back with an identical state_hash()")

	# The owner must come from the save itself, not from the rescuer's work:
	# with the colonist's work cleared, only the persisted record can name it.
	var without_work := read_state.duplicate(true)
	for entity in (without_work["entities"] as Array):
		if String(entity.get("id", "")) == String(rescuer["id"]):
			entity["work"] = null
	var from_record: WorldStateType = WorldStateType.from_save_state(without_work)
	_expect(String(from_record._progress_table.owners.get(scoped_key, "")) == scope,
		"the persisted owner record alone must restore the scoped key's owner")

func _owners_state(owners: Array) -> Dictionary:
	var world := WorldStateType.new(450002, 1)
	var state := world.to_save_state()
	state["workProgress"] = []
	for entry in owners:
		var progress := {"target": entry["target"], "ticksRemaining": 3}
		if entry.has("ownerJobId"):
			progress["ownerJobId"] = entry["ownerJobId"]
		state["workProgress"].append(progress)
	state["workProgressOwners"] = owners
	return state

func _check_owner_validation_allows_two_rescues_on_one_tile() -> void:
	var tile := {"x": 3, "y": 4}
	var two_rescues := _owners_state([
		{"target": tile, "jobId": "job_10", "ownerJobId": "job_10"},
		{"target": tile, "jobId": "job_9", "ownerJobId": "job_9"},
		{"target": tile, "jobId": "job_11"},
	])
	var ok := SaveIOType._validate_state(two_rescues)
	_expect(ok.get("ok", false), "two rescues and a plain owner on one tile must validate: %s" % ok)
	var duplicate := _owners_state([
		{"target": tile, "jobId": "job_9", "ownerJobId": "job_9"},
		{"target": tile, "jobId": "job_9", "ownerJobId": "job_9"},
	])
	_expect(not SaveIOType._validate_state(duplicate).get("ok", true), "a duplicate (ownerJobId, target) pair must be rejected")
	var duplicate_plain := _owners_state([{"target": tile, "jobId": "job_9"}, {"target": tile, "jobId": "job_8"}])
	_expect(not SaveIOType._validate_state(duplicate_plain).get("ok", true), "a duplicate plain target must still be rejected")
	var bad_scope := _owners_state([{"target": tile, "jobId": "job_9", "ownerJobId": "Job 9"}])
	_expect(not SaveIOType._validate_state(bad_scope).get("ok", true), "an ownerJobId outside the id pattern must be rejected")

func _check_ground_berries_change_state_hash() -> void:
	var a := WorldStateType.new(450003, 2)
	var b := WorldStateType.new(450003, 2)
	_expect(a.state_hash() == b.state_hash(), "setup: two worlds from one seed must hash equal")
	b._item_table.spawn_berries_item(3, 3)
	_expect(a.state_hash() != b.state_hash(), "a world with ground berries must not hash equal to one without")
	a._item_table.spawn_berries_item(3, 3)
	_expect(a.state_hash() == b.state_hash(), "the same ground berries must hash equal")
	b._item_table.spawn_berries_item(3, 3)
	_expect(a.state_hash() != b.state_hash(), "a different berry count must change state_hash()")
	b._item_table.consume_ground_berry(3, 3)
	_expect(a.state_hash() == b.state_hash(), "eating back to the same count must hash equal again")

func _check_ground_berry_factions_survive_save_load() -> void:
	var world := WorldStateType.new(450004, 2)
	world._item_table.spawn_berries_item(2, 2)
	world._item_table.spawn_berries_item(5, 1)
	world._item_table.ground_berries_factions["5_1"] = "wildlife"
	var state := world.to_save_state()
	var read_state := _save_and_read(state, "berry_factions.json")
	if read_state.is_empty():
		return
	var loaded: WorldStateType = WorldStateType.from_save_state(read_state)
	_expect(loaded.get_ground_berries_faction_id(2, 2) == "colony", "a colony berry pile must still be 'colony' after a load")
	_expect(loaded.get_ground_berries_faction_id(5, 1) == "wildlife", "a non-default berry faction must survive a load")
	_expect(loaded.get_ground_berries(2, 2) == 1 and loaded.get_ground_berries(5, 1) == 1, "berry counts must survive a load")
	_expect(loaded.state_hash() == world.state_hash(), "a save/load with ground berries must keep state_hash()")
