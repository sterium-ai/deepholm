extends SceneTree

## Shared header, helpers and members of the test_tool_items* checks (split by subject in R15);
## the checks themselves live in the test_tool_items*.gd files that extend this script.

## Covers axe/pick tool items and their persistence.
## content/items.json declares axe and pick as kind "tool"; content/jobs.json's
## dig/chop declare needs_tool; WorldState gains identity-bearing tool item
## storage (ground/held/stockpile location) plus an item reservation map
## (colonist-ai.md 3.4's "no reservation outlives its job" invariant, reused
## via reservation_invariants.gd). Also covers the fetch_tool toil
## (colonist-ai.md 2/3.3): see _check_fetch_tool_success_frees_no_travel() and
## _check_blocked_no_tool_frees_colonist_for_other_work() below; drop_tool and
## the foreign-reservation handover wait
## (_check_foreign_reservation_triggers_drop_tool_handover()) and the
## destroyed-mid-job failure path
## (_check_destroyed_tool_fails_job_and_requeues_with_backoff()).

const WorldStateType = preload("res://scripts/core/world_state.gd")
const Scenarios = preload("res://scripts/tests/support/scenarios.gd")
const StateCodecType = preload("res://scripts/core/persistence/state_codec.gd")
const SaveIOType = preload("res://scripts/core/persistence/save_io.gd")
const ReservationInvariantsType = preload("res://scripts/core/jobs/reservation_invariants.gd")
const ITEMS_CONTENT_PATH := "res://content/items.json"
const JOBS_CONTENT_PATH := "res://content/jobs.json"
const SAVE_IO_TEST_PATH := "user://test-tool-items-save-io.json"

var _failed := false

func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failed = true
		push_error(message)

## A 4x1 soil corridor with one colonist at its near end and a dig target two
## tiles away: enough for the scheduler to assign and activate a real dig job
## after a single tick(), without letting it run to natural completion.
func _build_single_dig_world(seed_value: int) -> WorldStateType:
	var world := WorldStateType.new(seed_value)
	TestAccess.tile_grid(world).tiles.fill(WorldStateType.TILE_ROCK)
	for x in range(0, 4):
		TestAccess.set_tile(world, x, 0, WorldStateType.TILE_SOIL)
	TestAccess.colonists(world).clear()
	TestAccess.colonists(world).append({"id": "colonist_0", "kind": "colonist", "x": 0, "y": 0, "route": null, "work": null})
	return world

## The single wood item still on the ground, or {} when none: place() now
## always mints a fresh item id (hands entries have no id of
## their own to preserve across a pick_up/place round trip), so a delivered
## item's final ground location must be found by kind, not by its original
## "item_1" id.
func _wood_item(world: WorldStateType) -> Dictionary:
	for item in TestAccess.item_table(world).items.values():
		if String(item["kind"]) == "wood":
			return item
	return {}

func _find_job_colonist_id(world: WorldStateType, job_id: String) -> String:
	var assignments := world.get_assignments()
	for worker in assignments:
		if String(assignments[worker]["job_id"]) == job_id:
			return String(worker)
	return ""

## A job completed before the save must be unknown to the restored world (v2 saves
## live jobs only, ADR 053); any other must have completed there.
func _restored_job_done(restored: WorldStateType, job_id: String, completed_before_save: Dictionary) -> bool:
	var job := Scenarios.find_job(restored, job_id)
	if completed_before_save.has(job_id):
		return job.is_empty()
	return String(job.get("status", "")) == "completed"
