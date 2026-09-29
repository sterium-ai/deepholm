extends SceneTree

## Acceptance coverage for issue #450's `build_line` command (docs/decisions/
## 040, extends docs/decisions/038's construction-site model): a batch of
## tiles submitted as one command instead of one `build` per tile, so a wall
## line or a rectangle drag creates every site in one atomic step and the
## enclosure check sees the whole shape at once. `test_build.gd`/
## `test_construction_site.gd` own the single-tile `build`/site-lifecycle
## contract; this file owns `build_line`'s own batch-specific behaviour:
## row-major canonicalization regardless of caller order, per-tile occupancy
## skipping without failing the rest of the batch, whole-set enclosure
## rejection with zero sites/reservations, and that cancelling sites the
## batch created is ordinary per-site `cancel_site` with no cross-site
## leakage.

const WorldStateType = preload("res://scripts/core/world_state.gd")
const ReservationInvariantsType = preload("res://scripts/core/jobs/reservation_invariants.gd")
const InventoryType = preload("res://scripts/core/actors/components/inventory.gd")
const StateCodecType = preload("res://scripts/core/persistence/state_codec.gd")

const MAX_TICKS := 400
const CANCEL_TEST_MAX_TICKS := 600

var _failed := false

func _init() -> void:
	_check_five_tile_line_creates_five_sites_in_row_major_order_regardless_of_input_order()
	_check_rectangle_with_occupied_tile_skips_it_and_builds_the_rest()
	_check_invalid_payload_rejections()
	_check_unknown_or_non_buildable_kind_rejected()
	_check_line_that_would_enclose_rejects_whole_batch_with_zero_sites_and_reservations()
	_check_preview_matches_apply_including_skipped()
	_check_cancel_one_site_in_line_drops_only_its_own_material_then_cancelling_the_rest_leaves_no_orphans()
	_check_overlapping_footprints_within_one_batch_skip_the_later_origin_horizontal()
	_check_overlapping_footprints_within_one_batch_skip_the_later_origin_vertical()
	_check_batch_with_a_disconnected_unreachable_candidate_still_detects_enclosure()
	_check_hands_load_serves_four_one_quantity_blocks_with_a_single_pick_up()
	_check_three_colonists_build_three_blocks_concurrently_each_declared_ticks_after_delivery()
	_check_critical_need_interrupt_mid_chain_resumes_same_leg_no_material_lost()
	_check_cancel_mid_chain_drops_exactly_what_is_currently_held()
	_check_save_load_before_first_deposit_preserves_the_chain()
	_check_save_load_between_chained_deposits_preserves_the_chain()
	_check_chain_never_retargets_onto_a_sibling_already_at_its_own_capacity()
	_check_cancelling_future_destinations_mid_chain_drops_leftover_and_completes()
	_check_competing_deliveries_that_satisfy_remaining_sites_drop_leftover_and_complete()

	if _failed:
		quit(1)
		return
	print("test_wall_orders: PASS")
	quit(0)

func _fail(message: String) -> void:
	push_error(message)
	_failed = true

func _expect(condition: bool, message: String) -> void:
	if not condition:
		_fail(message)

func _build_world(seed_value: int) -> WorldStateType:
	var world := WorldStateType.new(seed_value)
	world._tiles.fill(WorldStateType.TILE_FLOOR)
	world._colonists.clear()
	world._objects.clear()
	return world

func _colonist(id: String, x: int, y: int) -> Dictionary:
	return {"id": id, "kind": "colonist", "x": x, "y": y,
		"needs": {"food": 100, "water": 100, "rest": 100},
		"route": null, "work": null, "carrying": null}

func _command(world: WorldStateType, command_id: String, command_type: String, payload: Dictionary) -> Dictionary:
	return world.apply({"actor": "test", "command_id": command_id, "tick": world.get_tick(),
		"type": command_type, "payload": payload})

func _command_ok(world: WorldStateType, command_id: String, command_type: String, payload: Dictionary) -> Dictionary:
	var result := _command(world, command_id, command_type, payload)
	_expect(bool(result.get("ok", false)), "%s must be accepted: %s" % [command_id, result])
	return result

func _reason_of(result: Dictionary) -> String:
	return String((result.get("rejection", {}) as Dictionary).get("reason", ""))

func _tile(x: int, y: int) -> Dictionary:
	return {"x": x, "y": y}

func _tiles_from(positions: Array[Vector2i]) -> Array:
	var tiles: Array = []
	for pos in positions:
		tiles.append(_tile(pos.x, pos.y))
	return tiles

func _add_stock(world: WorldStateType, kind: String, count: int, x: int, y: int) -> void:
	var id := "item_%d" % world._next_item_id
	world._items[id] = {"id": id, "x": x, "y": y, "kind": kind, "count": count}
	world._next_item_id += 1

func _held_quantity(site: Dictionary, item_kind: String) -> int:
	for entry in (site["held_materials"] as Array):
		if String(entry["item"]) == item_kind:
			return int(entry["quantity"])
	return -1

## Acceptance: "a 5-tile wall-line build_line command creates 5 construction
## sites, ids/positions in row-major order" -- the payload's own tiles array
## is deliberately shuffled to prove the command canonicalizes, never
## trusting caller order.
func _check_five_tile_line_creates_five_sites_in_row_major_order_regardless_of_input_order() -> void:
	var world := _build_world(450100)
	var shuffled: Array = [_tile(12, 20), _tile(10, 20), _tile(14, 20), _tile(11, 20), _tile(13, 20)]
	var result := _command_ok(world, "line", "build_line", {"kind": "wooden_wall", "tiles": shuffled})
	var sites: Array = result.get("sites", [])
	_expect(sites.size() == 5, "a 5-tile line must create exactly 5 sites, got %d: %s" % [sites.size(), result])
	_expect((result.get("skipped", []) as Array).is_empty(), "no tile in a clear line may be skipped: %s" % result)
	var expected_x := [10, 11, 12, 13, 14]
	for i in sites.size():
		var site: Dictionary = sites[i]
		_expect(int(site["x"]) == expected_x[i] and int(site["y"]) == 20,
			"site %d must be at (%d, 20) in row-major order, got %s" % [i, expected_x[i], site])
		var record := world.get_construction_site(int(site["x"]), int(site["y"]))
		_expect(not record.is_empty() and String(record["id"]) == String(site["id"]),
			"the reported site id must match a real construction site at (%d, 20)" % expected_x[i])
	var seen_ids := {}
	for site in sites:
		seen_ids[String(site["id"])] = true
	_expect(seen_ids.size() == 5, "every created site must have a distinct id: %s" % [sites])

## Acceptance: "a build_line rectangle including an occupied tile creates
## sites for every other tile and reports the occupied one in skipped with
## its reason."
func _check_rectangle_with_occupied_tile_skips_it_and_builds_the_rest() -> void:
	var world := _build_world(450200)
	world._colonists.append(_colonist("colonist_0", 31, 30))
	var rectangle: Array = []
	for y in range(30, 32):
		for x in range(30, 33):
			rectangle.append(_tile(x, y))
	var result := _command_ok(world, "rect", "build_line", {"kind": "wooden_wall", "tiles": rectangle})
	var sites: Array = result.get("sites", [])
	var skipped: Array = result.get("skipped", [])
	_expect(sites.size() == 5, "5 of the 6 rectangle tiles (one occupied by the colonist) must get sites, got %d: %s" % [sites.size(), result])
	_expect(skipped.size() == 1, "exactly one tile must be skipped, got %d: %s" % [skipped.size(), result])
	if skipped.size() == 1:
		var skip: Dictionary = skipped[0]
		_expect(int(skip["x"]) == 31 and int(skip["y"]) == 30,
			"the skipped tile must be the colonist's own tile (31, 30): %s" % skip
		)
		_expect(String(skip["reason"]) == "invalid_target",
			"the skipped tile must carry the same reason the single-tile command would have returned: %s" % skip)
	for site in sites:
		_expect(not (int(site["x"]) == 31 and int(site["y"]) == 30), "no site may be created on the colonist's own tile: %s" % [sites])
	_expect(world.get_construction_site(31, 30).is_empty(), "the occupied tile must never get a construction site")

func _check_invalid_payload_rejections() -> void:
	var world := _build_world(450300)
	var non_string_kind := _command(world, "a", "build_line", {"kind": 5, "tiles": [_tile(0, 0)]})
	_expect(_reason_of(non_string_kind) == "invalid_payload", "a non-string kind must be rejected invalid_payload: %s" % non_string_kind)
	var empty_tiles := _command(world, "b", "build_line", {"kind": "wooden_wall", "tiles": []})
	_expect(_reason_of(empty_tiles) == "invalid_payload", "an empty tiles array must be rejected invalid_payload: %s" % empty_tiles)
	var non_array_tiles := _command(world, "c", "build_line", {"kind": "wooden_wall", "tiles": "10,10"})
	_expect(_reason_of(non_array_tiles) == "invalid_payload", "a non-array tiles field must be rejected invalid_payload: %s" % non_array_tiles)
	var missing_y := _command(world, "d", "build_line", {"kind": "wooden_wall", "tiles": [{"x": 0}]})
	_expect(_reason_of(missing_y) == "invalid_payload", "a tile entry missing y must be rejected invalid_payload: %s" % missing_y)
	var bad_orientation := _command(world, "e", "build_line", {"kind": "wooden_wall", "tiles": [_tile(0, 0)], "orientation": "diagonal"})
	_expect(_reason_of(bad_orientation) == "invalid_payload", "an invalid orientation must be rejected invalid_payload: %s" % bad_orientation)

func _check_unknown_or_non_buildable_kind_rejected() -> void:
	var world := _build_world(450350)
	var unknown_kind := _command(world, "a", "build_line", {"kind": "not_a_real_kind", "tiles": [_tile(0, 0)]})
	_expect(_reason_of(unknown_kind) == "invalid_payload", "an unknown kind must be rejected invalid_payload: %s" % unknown_kind)
	var no_cost_kind := _command(world, "b", "build_line", {"kind": "table", "tiles": [_tile(0, 0)]})
	_expect(_reason_of(no_cost_kind) == "invalid_payload", "a kind with an empty build_cost must be rejected invalid_payload: %s" % no_cost_kind)

## Acceptance: "a build_line whose combined footprint would enclose a
## reachable area is rejected as a whole, typed blocked_target_unreachable,
## with zero sites created and zero reservations taken." The room's north
## side is left as one whole 4-tile opening (not a single-tile gap) so that
## sealing any ONE of those tiles alone would not enclose anything -- only
## submitting the entire row as one build_line command does, proving the
## enclosure check runs across the whole surviving set, not per tile.
func _check_line_that_would_enclose_rejects_whole_batch_with_zero_sites_and_reservations() -> void:
	var world := _build_world(450400)
	world._colonists.append(_colonist("colonist_0", 5, 5))
	# 4x4 room (x=4..7, y=4..7): south row, and the west/east columns minus
	# their north corners, are pre-built individually; the whole north row
	# (4 tiles) is left open for the build_line under test.
	for x in range(4, 8):
		_command_ok(world, "south_%d" % x, "build", {"kind": "wooden_wall", "x": x, "y": 7})
	for y in [5, 6]:
		_command_ok(world, "west_%d" % y, "build", {"kind": "wooden_wall", "x": 4, "y": y})
		_command_ok(world, "east_%d" % y, "build", {"kind": "wooden_wall", "x": 7, "y": y})
	var north_row: Array = [_tile(7, 4), _tile(4, 4), _tile(6, 4), _tile(5, 4)]
	var before_hash := world.state_hash()
	var result := _command(world, "seal", "build_line", {"kind": "wooden_wall", "tiles": north_row})
	_expect(_reason_of(result) == "blocked_target_unreachable",
		"sealing the whole remaining opening in one batch must be rejected blocked_target_unreachable: %s" % result)
	_expect(world.state_hash() == before_hash, "a rejected build_line must never mutate the world")
	var table := world._scheduler.queue.get_reservation_table()
	for tile in north_row:
		var pos := Vector2i(int(tile["x"]), int(tile["y"]))
		_expect(world.get_construction_site(pos.x, pos.y).is_empty(),
			"no site may exist at (%d, %d) after the whole batch was rejected" % [pos.x, pos.y])
		_expect(table.owner("tile:%d,%d" % [pos.x, pos.y]).is_empty(),
			"no reservation may be taken at (%d, %d) after the whole batch was rejected" % [pos.x, pos.y])

## Acceptance (WorldState.preview() gains the matching read-only check):
## preview() must agree with apply() on both the ok/reject verdict and the
## reported skipped tiles, and must never mutate the world either way.
func _check_preview_matches_apply_including_skipped() -> void:
	var world := _build_world(450500)
	world._colonists.append(_colonist("colonist_0", 21, 25))
	var tiles: Array = [_tile(20, 25), _tile(21, 25), _tile(22, 25)]
	var hash_before := world.state_hash()
	var preview_result := world.preview({"actor": "test", "command_id": "p", "tick": world.get_tick(),
		"type": "build_line", "payload": {"kind": "wooden_wall", "tiles": tiles}})
	_expect(bool(preview_result.get("ok", false)), "preview must accept a batch that apply() would accept: %s" % preview_result)
	_expect(world.state_hash() == hash_before, "preview must never mutate the world")
	var previewed_skipped: Array = preview_result.get("skipped", [])
	_expect(previewed_skipped.size() == 1 and int(previewed_skipped[0]["x"]) == 21,
		"preview must report the same skipped tile apply() will report: %s" % preview_result)
	var applied := _command_ok(world, "a", "build_line", {"kind": "wooden_wall", "tiles": tiles})
	var applied_skipped: Array = applied.get("skipped", [])
	_expect(applied_skipped.size() == 1 and int(applied_skipped[0]["x"]) == 21,
		"apply must report the same skipped tile preview reported: %s" % applied)
	_expect((applied.get("sites", []) as Array).size() == 2, "apply must create sites for the 2 clear tiles: %s" % applied)

## Acceptance: "cancelling one site in a line drops only its own held
## material; cancelling every site in the line leaves find_orphaned_
## reservations() empty -- both exercise only already-existing per-site
## mechanics."
func _check_cancel_one_site_in_line_drops_only_its_own_material_then_cancelling_the_rest_leaves_no_orphans() -> void:
	var world := _build_world(450600)
	world._colonists.append(_colonist("colonist_0", 0, 0))
	_command_ok(world, "zone", "zone_add", {"x": 0, "y": 0, "width": 1, "height": 1})
	_add_stock(world, "wood", 20, 0, 0)
	var positions: Array[Vector2i] = [Vector2i(10, 10), Vector2i(11, 10), Vector2i(12, 10)]
	var result := _command_ok(world, "line", "build_line", {"kind": "wooden_wall", "tiles": _tiles_from(positions)})
	_expect((result.get("sites", []) as Array).size() == 3, "the fixture line must create 3 sites: %s" % result)

	# Which of the 3 sites the shared scheduler delivers to first is an
	# implementation detail of GlobalAssignmentScheduler, not this command's
	# own contract -- this scenario only needs ANY one of them holding
	# material to prove cancelling it leaves its siblings untouched.
	var delivered_to: Vector2i = Vector2i(-1, -1)
	for _i in CANCEL_TEST_MAX_TICKS:
		world.tick()
		for pos in positions:
			var site := world.get_construction_site(pos.x, pos.y)
			if not site.is_empty() and _held_quantity(site, "wood") > 0:
				delivered_to = pos
				break
		if delivered_to.x >= 0:
			break
	_expect(delivered_to.x >= 0, "the fixture must reach a tick where some site in the line already holds delivered wood")

	var cancelled_before := world.get_construction_site(delivered_to.x, delivered_to.y)
	var cancelled_wood_before := _held_quantity(cancelled_before, "wood")
	var siblings: Array[Vector2i] = []
	for pos in positions:
		if pos != delivered_to:
			siblings.append(pos)
	_command_ok(world, "cancel_delivered", "cancel_site", {"x": delivered_to.x, "y": delivered_to.y})
	_expect(world.get_construction_site(delivered_to.x, delivered_to.y).is_empty(), "cancel_site must remove the cancelled site")
	for sibling in siblings:
		_expect(not world.get_construction_site(sibling.x, sibling.y).is_empty(),
			"cancelling one site must not affect a sibling site at (%d, %d)" % [sibling.x, sibling.y])

	var dropped_wood := 0
	for item in world.get_items():
		var tile := Vector2i(int(item["x"]), int(item["y"]))
		if String(item["kind"]) == "wood" and absi(tile.x - delivered_to.x) <= 1 and absi(tile.y - delivered_to.y) <= 1:
			dropped_wood += int(item["count"])
	_expect(dropped_wood == cancelled_wood_before,
		"cancelling the site must drop exactly its own held wood (%d), found %d nearby" % [cancelled_wood_before, dropped_wood])

	for sibling in siblings:
		_command_ok(world, "cancel_%d_%d" % [sibling.x, sibling.y], "cancel_site", {"x": sibling.x, "y": sibling.y})
	_expect(world.get_construction_sites().is_empty(), "no construction site may remain once every site in the line is cancelled")
	var orphans := ReservationInvariantsType.find_orphaned_reservations(
		world._scheduler.queue.get_reservation_table(), world._scheduler.queue.get_jobs())
	_expect(orphans.is_empty(), "find_orphaned_reservations() must be empty once every site in the line is cancelled (found %s)" % [orphans])

## Regression (review round 1): "workbench"'s footprint is [2, 1] -- two tiles
## wide. Origins (10, 10) and (11, 10) both individually pass the single-tile
## occupancy check (neither one's own reservation exists in the table yet
## during classification), but their footprints share tile (11, 10). Before
## the fix, both "survived" and _apply_build_line_command() created two sites
## that both tried to acquire (11, 10), leaving the second with an incomplete
## reservation and making queries on that tile ambiguous. Only the row-major
## FIRST origin may survive; the second must be skipped invalid_target, and
## preview must report the same verdict apply does. Cancelling the surviving
## site via either of its own footprint tiles must remove it wholly and
## release both of its reservations -- there is no second site left to leak.
func _check_overlapping_footprints_within_one_batch_skip_the_later_origin_horizontal() -> void:
	var world := _build_world(450700)
	var payload := {"kind": "workbench", "tiles": [_tile(10, 10), _tile(11, 10)]}
	var hash_before := world.state_hash()
	var preview_result := world.preview({"actor": "test", "command_id": "p", "tick": world.get_tick(),
		"type": "build_line", "payload": payload})
	_expect(world.state_hash() == hash_before, "preview must never mutate the world")
	var result := _command_ok(world, "h", "build_line", payload)
	var sites: Array = result.get("sites", [])
	var skipped: Array = result.get("skipped", [])
	_expect(sites.size() == 1, "only the first overlapping origin may create a site, got %d: %s" % [sites.size(), result])
	_expect(skipped.size() == 1, "the later overlapping origin must be skipped, got %d: %s" % [skipped.size(), result])
	if skipped.size() == 1:
		_expect(int(skipped[0]["x"]) == 11 and int(skipped[0]["y"]) == 10 and String(skipped[0]["reason"]) == "invalid_target",
			"the later origin (11, 10) must be skipped invalid_target: %s" % skipped[0])
	var previewed_skipped: Array = preview_result.get("skipped", [])
	_expect(previewed_skipped.size() == 1 and int(previewed_skipped[0]["x"]) == 11,
		"preview must report the same skip apply reported: %s" % preview_result)
	if sites.is_empty():
		return
	var site: Dictionary = sites[0]
	_expect(int(site["x"]) == 10 and int(site["y"]) == 10, "the surviving site must be at the first origin (10, 10): %s" % site)
	var table := world._scheduler.queue.get_reservation_table()
	var owner := world._sites.owner_key(String(site["id"]))
	_expect(table.owner("tile:10,10") == owner and table.owner("tile:11,10") == owner,
		"the single surviving site must hold the reservation for both of its own footprint tiles")
	_expect(String(world.get_construction_site(11, 10).get("id", "")) == String(site["id"]),
		"tile (11, 10) must resolve to the same single site, not a second phantom site")
	_command_ok(world, "cancel_h", "cancel_site", {"x": 11, "y": 10})
	_expect(world.get_construction_site(10, 10).is_empty() and world.get_construction_site(11, 10).is_empty(),
		"cancelling via either footprint tile must remove the one site entirely")
	_expect(table.owner("tile:10,10").is_empty() and table.owner("tile:11,10").is_empty(),
		"cancelling the site must release both of its footprint reservations")

## Vertical variant of the same overlap: orientation "vertical" turns
## workbench's [2, 1] footprint into [1, 2], so origins (20, 20) and (20, 21)
## share tile (20, 21) instead.
func _check_overlapping_footprints_within_one_batch_skip_the_later_origin_vertical() -> void:
	var world := _build_world(450750)
	var payload := {"kind": "workbench", "orientation": "vertical", "tiles": [_tile(20, 20), _tile(20, 21)]}
	var result := _command_ok(world, "v", "build_line", payload)
	var sites: Array = result.get("sites", [])
	var skipped: Array = result.get("skipped", [])
	_expect(sites.size() == 1, "only the first overlapping origin may create a site, got %d: %s" % [sites.size(), result])
	_expect(skipped.size() == 1 and int(skipped[0]["x"]) == 20 and int(skipped[0]["y"]) == 21
			and String(skipped[0]["reason"]) == "invalid_target",
		"the later origin (20, 21) must be skipped invalid_target: %s" % skipped)
	if sites.is_empty():
		return
	var table := world._scheduler.queue.get_reservation_table()
	var owner := world._sites.owner_key(String(sites[0]["id"]))
	_expect(table.owner("tile:20,20") == owner and table.owner("tile:20,21") == owner,
		"the single surviving vertical site must hold the reservation for both of its own footprint tiles")

## Regression (review round 1): _would_enclose_tiles() must not subtract the
## WHOLE candidate set's size from a single reachable component's baseline.
## Only (1,1)-(3,1) and the isolated (10,10) are passable; a colonist at
## (1,1) can reach (1,1)-(3,1) but never (10,10), a disconnected one-tile
## pocket. Building wooden_wall on (2,1) alone would strand (3,1) -- before
## the fix, adding the unrelated, unreachable (10,10) as a second candidate
## in the same batch made the formula compare "before.size() - tiles.size()"
## (3 - 2 = 1) against the correct after.size() (1), wrongly passing (1 < 1
## is false) a batch that must still be rejected.
func _check_batch_with_a_disconnected_unreachable_candidate_still_detects_enclosure() -> void:
	var world := _build_world(450800)
	world._tiles.fill(WorldStateType.TILE_ROCK)
	for x in [1, 2, 3]:
		world._tiles[world._tile_index(x, 1)] = WorldStateType.TILE_FLOOR
	world._tiles[world._tile_index(10, 10)] = WorldStateType.TILE_FLOOR
	world._colonists.append(_colonist("colonist_0", 1, 1))
	var payload := {"kind": "wooden_wall", "tiles": [_tile(2, 1), _tile(10, 10)]}
	var hash_before := world.state_hash()
	var preview_result := world.preview({"actor": "test", "command_id": "p", "tick": world.get_tick(),
		"type": "build_line", "payload": payload})
	_expect(_reason_of(preview_result) == "blocked_target_unreachable",
		"preview must reject the disconnected-component batch blocked_target_unreachable: %s" % preview_result)
	_expect(world.state_hash() == hash_before, "preview must never mutate the world")
	var result := _command(world, "seal_disconnected", "build_line", payload)
	_expect(_reason_of(result) == "blocked_target_unreachable",
		"apply must reject the disconnected-component batch blocked_target_unreachable: %s" % result)
	_expect(world.state_hash() == hash_before, "a rejected build_line must never mutate the world")
	_expect(world.get_construction_site(2, 1).is_empty() and world.get_construction_site(10, 10).is_empty(),
		"no site may exist after the whole batch was rejected")
	var table := world._scheduler.queue.get_reservation_table()
	_expect(table.owner("tile:2,1").is_empty() and table.owner("tile:10,10").is_empty(),
		"no reservation may be taken after the whole batch was rejected")

## Total "pick_up" toil completions across world's whole run so far
## (ToilExecutor.trace, test_architecture_rules.gd's own execution-trace
## mechanism -- never consulted by production code, purely additive).
func _pick_up_count(world: WorldStateType) -> int:
	var count := 0
	for entry in world._toils.trace:
		if String(entry.get("toil", "")) == "pick_up" and String(entry.get("phase", "")) == "complete":
			count += 1
	return count

## Acceptance (issue #451, docs/decisions/041): a colonist whose hands hold 4
## units of wood must deliver to 4 separate one-quantity wall blocks in a row
## with no intervening trip back to the stockpile -- asserted directly by the
## pick_up count (one hop consumes the entire 4-unit stack and every block
## gets built from it), not merely by observing all 4 blocks eventually
## complete.
func _check_hands_load_serves_four_one_quantity_blocks_with_a_single_pick_up() -> void:
	var world := _build_world(451100)
	world._colonists.append(_colonist("colonist_0", 0, 0))
	_command_ok(world, "zone", "zone_add", {"x": 0, "y": 0, "width": 1, "height": 1})
	_add_stock(world, "wood", 4, 0, 0)
	var positions: Array[Vector2i] = [Vector2i(10, 10), Vector2i(11, 10), Vector2i(12, 10), Vector2i(13, 10)]
	var result := _command_ok(world, "line", "build_line", {"kind": "wooden_wall", "tiles": _tiles_from(positions)})
	_expect((result.get("sites", []) as Array).size() == 4, "the fixture line must create 4 sites: %s" % result)
	var completed := false
	for _i in MAX_TICKS:
		world.tick()
		var all_built := true
		for pos in positions:
			if world.get_object(pos.x, pos.y) != "wooden_wall":
				all_built = false
		if all_built:
			completed = true
			break
	_expect(completed, "all 4 wall blocks must complete within the tick budget")
	_expect(_pick_up_count(world) == 1,
		"a single hands-load must serve all 4 blocks with exactly one pick_up trip, got %d" % _pick_up_count(world))
	var wood_left := 0
	for item in world.get_items():
		if String(item["kind"]) == "wood":
			wood_left += int(item["count"])
	_expect(wood_left == 0, "all 4 units of wood must be fully consumed, %d left on the ground" % wood_left)

## Acceptance: chaining must not disturb ordinary N-builder concurrency -- 3
## build-enabled colonists, each fed its own separate 1-unit wood stock, must
## still complete 3 different one-quantity blocks concurrently, each finishing
## build_ticks (plus only the small, already-documented scheduling latency
## test_construction_site.gd's own completion-timing check tolerates) after
## its own material lands.
func _check_three_colonists_build_three_blocks_concurrently_each_declared_ticks_after_delivery() -> void:
	var world := _build_world(451200)
	for i in range(3):
		world._colonists.append(_colonist("colonist_%d" % i, i * 3, 0))
	_command_ok(world, "zone", "zone_add", {"x": 0, "y": 0, "width": 9, "height": 1})
	for i in range(3):
		_add_stock(world, "wood", 1, i * 3, 0)
	var positions: Array[Vector2i] = [Vector2i(20, 20), Vector2i(21, 20), Vector2i(22, 20)]
	var result := _command_ok(world, "line", "build_line", {"kind": "wooden_wall", "tiles": _tiles_from(positions)})
	_expect((result.get("sites", []) as Array).size() == 3, "the fixture line must create 3 sites: %s" % result)
	var declared_ticks := int(world._object_definitions["wooden_wall"]["build_ticks"])
	var delivered_tick := {}
	var completed_tick := {}
	for _i in MAX_TICKS:
		world.tick()
		for pos in positions:
			var key := "%d,%d" % [pos.x, pos.y]
			if not delivered_tick.has(key):
				var site := world.get_construction_site(pos.x, pos.y)
				if not site.is_empty() and _held_quantity(site, "wood") >= 1:
					delivered_tick[key] = world.get_tick()
			if not completed_tick.has(key) and world.get_object(pos.x, pos.y) == "wooden_wall":
				completed_tick[key] = world.get_tick()
		if completed_tick.size() == 3:
			break
	_expect(completed_tick.size() == 3,
		"all three blocks must complete within budget (delivered=%s, completed=%s)" % [delivered_tick, completed_tick])
	for pos in positions:
		var key := "%d,%d" % [pos.x, pos.y]
		_expect(delivered_tick.has(key), "block (%s) must have received its own material" % key)
		if not delivered_tick.has(key) or not completed_tick.has(key):
			continue
		var elapsed := int(completed_tick[key]) - int(delivered_tick[key])
		_expect(elapsed >= declared_ticks and elapsed <= declared_ticks + 5,
			"block (%s) must finish build_ticks (%d) after its own material lands, plus only a small scheduling latency (got %d)"
				% [key, declared_ticks, elapsed])

## Shared mid-chain fixture (issue #451): a single colonist, a single 3-unit
## wood stock exactly matching 3 spaced-out one-quantity wall sites' combined
## need, ticked until a site_fetch job has already chained past its own FIRST
## site (job["site"] no longer names it) while its colonist still carries
## material and is strictly mid-walk toward the chained site -- the same
## "caught between two toils" boundary test_build.gd's own mid-fetch checks
## rely on. Sites are spaced 3 tiles apart (not adjacent) so the transit
## between them spans enough ticks to reliably catch this window. Returns {}
## on setup/timeout failure, otherwise {"world", "job_id", "chained_site",
## "held"}.
func _reach_mid_chain(seed_value: int) -> Dictionary:
	var world := _build_world(seed_value)
	world._colonists.append(_colonist("colonist_0", 0, 0))
	_command_ok(world, "zone", "zone_add", {"x": 0, "y": 0, "width": 1, "height": 1})
	_add_stock(world, "wood", 3, 0, 0)
	var positions: Array[Vector2i] = [Vector2i(10, 10), Vector2i(13, 10), Vector2i(16, 10)]
	var result := _command_ok(world, "line", "build_line", {"kind": "wooden_wall", "tiles": _tiles_from(positions)})
	var sites: Array = result.get("sites", [])
	if sites.size() != 3:
		_fail("the mid-chain fixture must create 3 sites: %s" % result)
		return {}
	var first_origin := Vector2i(int(sites[0]["x"]), int(sites[0]["y"]))
	for _i in MAX_TICKS:
		world.tick()
		for job in world.get_jobs():
			if String(job.get("kind", "")) != "site_fetch" or job.get("site") == null:
				continue
			var site: Vector2i = job["site"]
			if site == first_origin:
				continue
			var colonist := world._find_colonist("colonist_0")
			if InventoryType.is_carrying(colonist) and colonist.get("route") != null:
				return {"world": world, "job_id": String(job["id"]), "chained_site": site,
					"held": InventoryType.count_of_kind(colonist, "wood")}
	return {}

## Acceptance (issue #451): a critical-need interrupt mid-chain must pause and
## resume at the SAME leg (the chained site the job had already retargeted
## onto, not the first one), losing no held material -- exercising the
## ordinary ADR 009 interrupt boundary directly (world._interrupt_current_job/
## _resume_interrupted_job(), test_build.gd's own established pattern),
## adapted to a job that has already retargeted mid-chain.
func _check_critical_need_interrupt_mid_chain_resumes_same_leg_no_material_lost() -> void:
	var state := _reach_mid_chain(451300)
	_expect(not state.is_empty(), "setup must reach a mid-chain state (already chained past the first site, still carrying, mid-walk)")
	if state.is_empty():
		return
	var world: WorldStateType = state["world"]
	var job_id: String = state["job_id"]
	var chained_site: Vector2i = state["chained_site"]
	var held_before: int = state["held"]
	_expect(held_before > 0, "the mid-chain fixture must catch the colonist still carrying material")
	var colonist := world._find_colonist("colonist_0")
	world._interrupt_current_job(colonist)
	_expect(String(world._scheduler.queue.get_job(job_id).get("status", "")) == "queued",
		"a critical-need interrupt mid-chain must suspend the job back to queued")
	_expect(InventoryType.count_of_kind(colonist, "wood") == held_before, "the interrupt must not lose any held material")
	_expect(world._scheduler.queue.get_job(job_id)["site"] == chained_site,
		"the suspended job must still name the chained site, not the first one")
	world._resume_interrupted_job("colonist_0")
	var resumed_job := world._scheduler.queue.get_job(job_id)
	_expect(String(resumed_job.get("status", "")) == "active", "resuming a mid-chain interrupt must reactivate the same job")
	_expect(resumed_job.get("site") == chained_site, "resuming must continue at the SAME chained leg, not the first site")
	_expect(InventoryType.count_of_kind(world._find_colonist("colonist_0"), "wood") == held_before,
		"no held material may be lost across resume")
	var completed := false
	for _i in MAX_TICKS:
		world.tick()
		if world.get_construction_sites().is_empty():
			completed = true
			break
	_expect(completed, "the interrupted chain must resume and finish building every site within budget")

## Acceptance (issue #451): cancelling mid-chain must drop exactly what the
## colonist currently holds (already less than the original hands-load, since
## earlier sites in the chain already consumed some of it) at its own current
## tile -- the existing terminal-drop path (#400's rule), unchanged.
func _check_cancel_mid_chain_drops_exactly_what_is_currently_held() -> void:
	var state := _reach_mid_chain(451400)
	_expect(not state.is_empty(), "setup must reach a mid-chain state")
	if state.is_empty():
		return
	var world: WorldStateType = state["world"]
	var job_id: String = state["job_id"]
	var held_before: int = state["held"]
	var colonist := world._find_colonist("colonist_0")
	var drop_tile := Vector2i(int(colonist["x"]), int(colonist["y"]))
	_command_ok(world, "cancel_mid_chain", "cancel_job", {"job_id": job_id})
	_expect(String(world._scheduler.queue.get_job(job_id).get("status", "")) == "cancelled", "cancelling mid-chain must cancel the job")
	_expect(not InventoryType.is_carrying(world._find_colonist("colonist_0")), "cancelling mid-chain must empty the colonist's hands")
	var dropped := 0
	for item in world.get_items():
		if String(item["kind"]) == "wood" and Vector2i(int(item["x"]), int(item["y"])) == drop_tile:
			dropped += int(item["count"])
	_expect(dropped == held_before,
		"cancelling mid-chain must drop exactly what was currently held (%d), found %d" % [held_before, dropped])

## The one active site_fetch job for a single-colonist fixture, or "" if none.
func _active_site_fetch_job_id(world: WorldStateType) -> String:
	for job in world.get_jobs():
		if String(job.get("kind", "")) == "site_fetch" and String(job.get("status", "")) == "active":
			return String(job["id"])
	return ""

## Ticks world until colonist_0 is carrying exactly `count` units of `kind`
## and no site in `positions` has received any of it yet -- "hands loaded,
## before the first delivery." False on timeout.
func _reach_hands_loaded_before_any_delivery(world: WorldStateType, kind: String, count: int, positions: Array[Vector2i]) -> bool:
	for _i in MAX_TICKS:
		world.tick()
		var colonist := world._find_colonist("colonist_0")
		if InventoryType.count_of_kind(colonist, kind) != count:
			continue
		var any_delivered := false
		for pos in positions:
			var site := world.get_construction_site(pos.x, pos.y)
			if not site.is_empty() and _held_quantity(site, kind) > 0:
				any_delivered = true
		if not any_delivered:
			return true
	return false

func _total_ground_kind(world: WorldStateType, kind: String) -> int:
	var total := 0
	for item in world.get_items():
		if String(item["kind"]) == kind:
			total += int(item["count"])
	return total

## Regression (round-1 review, issue #451): _toil_on_deposit_success() used to
## resolve the delivery kind from _site_fetch_picked_kind, a runtime cache
## never saved by state_codec.gd -- a save/load taken before the job's first
## deposit left the cache empty after load, so the very next deposit read
## kind as "" and completed the job instead of continuing to chain, even
## though hands still held material for the remaining sites. This save/load
## happens before pick_up itself even runs a second time, so it also proves
## the fix does not depend on _site_fetch_picked_kind having been populated at
## all this session.
##
## Regression (round-2 review, issue #451): asserting only "eventually all 4
## complete with empty hands" cannot distinguish a preserved chain from a
## prematurely-completed job whose dropped leftover got hauled and re-fetched
## by a brand new job -- both would satisfy that assertion. This now drives
## the unloaded source and its restore identically, tick for tick, and
## requires state_hash() to match every tick (test_save_determinism.gd's own
## save/load idiom); requires the SAME job_id (not a replacement) to reach
## "completed" in both copies; and requires neither copy to ever record a
## second pick_up (the unloaded source's trace against its own pre-load count,
## the restore's fresh trace against zero, since ToilExecutor.trace is
## diagnostic-only and is not itself part of the persisted save state),
## proving no leftover was ever dropped and re-fetched by a replacement job.
func _check_save_load_before_first_deposit_preserves_the_chain() -> void:
	var world := _build_world(451500)
	world._colonists.append(_colonist("colonist_0", 0, 0))
	_command_ok(world, "zone", "zone_add", {"x": 0, "y": 0, "width": 1, "height": 1})
	_add_stock(world, "wood", 4, 0, 0)
	var positions: Array[Vector2i] = [Vector2i(10, 10), Vector2i(11, 10), Vector2i(12, 10), Vector2i(13, 10)]
	var result := _command_ok(world, "line", "build_line", {"kind": "wooden_wall", "tiles": _tiles_from(positions)})
	_expect((result.get("sites", []) as Array).size() == 4, "the fixture line must create 4 sites: %s" % result)
	_expect(_reach_hands_loaded_before_any_delivery(world, "wood", 4, positions),
		"setup must reach hands carrying all 4 units before any site has received material")
	var job_id := _active_site_fetch_job_id(world)
	_expect(not job_id.is_empty(), "colonist_0's own active site_fetch job must be found before save/load")
	var pick_ups_before_load := _pick_up_count(world)
	_expect(pick_ups_before_load == 1, "setup must reach hands-loaded with exactly one pick_up")

	var loaded: WorldStateType = StateCodecType.decode(StateCodecType.encode(world))
	_expect(loaded.state_hash() == world.state_hash(),
		"a save/load taken before the first deposit must match the source's hash before any further ticks")

	var completed := false
	for _i in MAX_TICKS:
		world.tick()
		loaded.tick()
		_expect(world.state_hash() == loaded.state_hash(),
			"the unloaded source and its pre-deposit restore must keep matching state_hash() every tick while driven identically")
		if not completed:
			var all_built := true
			for pos in positions:
				if loaded.get_object(pos.x, pos.y) != "wooden_wall":
					all_built = false
			if all_built:
				completed = true
	_expect(completed, "a save/load taken before the first deposit must not truncate the chain: all 4 blocks must still complete")
	_expect(not InventoryType.is_carrying(loaded._find_colonist("colonist_0")),
		"hands must be empty once the reloaded chain finishes")
	_expect(String(loaded._scheduler.queue.get_job(job_id).get("status", "")) == "completed",
		"the SAME job active before save/load must be the one that serves every remaining destination, not a replacement")
	_expect(_pick_up_count(world) == pick_ups_before_load,
		"the uninterrupted source must not need any additional pick_up either: all 4 blocks come from the one hands-load")
	_expect(_pick_up_count(loaded) == 0,
		"no additional pick_up may occur after loading: the restore's fresh trace must record zero, since the whole chain finishes on the material already in hands at load time")

## Regression (round-1 review, issue #451): same defect as above, but the
## save/load lands strictly BETWEEN two chained deposits (job already
## retargeted onto its second site, first site already fully served) --
## exactly the window _reach_mid_chain() catches -- proving a chain already
## in progress survives a reload, not only one that has not yet started.
##
## Regression (round-2 review, issue #451): as above, "eventually empty hands"
## alone cannot rule out a premature completion plus a drop-and-re-fetch
## masquerading as a preserved chain. This drives the unloaded source (still
## holding the pre-load material) and its restore identically, tick for tick,
## requires state_hash() to match every tick, requires the SAME job_id to
## reach "completed" in both copies, and requires neither copy to ever record
## a second pick_up (the source's trace against its own pre-load count, the
## restore's fresh trace -- ToilExecutor.trace is diagnostic-only and is not
## itself part of the persisted save state -- against zero).
func _check_save_load_between_chained_deposits_preserves_the_chain() -> void:
	var state := _reach_mid_chain(451600)
	_expect(not state.is_empty(), "setup must reach a mid-chain state")
	if state.is_empty():
		return
	var job_id: String = state["job_id"]
	var chained_site: Vector2i = state["chained_site"]
	var held_before: int = state["held"]
	var world: WorldStateType = state["world"]
	var pick_ups_before_load := _pick_up_count(world)
	var loaded: WorldStateType = StateCodecType.decode(StateCodecType.encode(world))
	var resumed_job := loaded._scheduler.queue.get_job(job_id)
	_expect(resumed_job.get("site") == chained_site, "the job must still name the chained site immediately after load")
	_expect(InventoryType.count_of_kind(loaded._find_colonist("colonist_0"), "wood") == held_before,
		"held material must survive the save/load round trip exactly")
	_expect(loaded.state_hash() == world.state_hash(),
		"a save/load taken mid-chain must match the unloaded source's hash before any further ticks")

	var completed := false
	for _i in MAX_TICKS:
		world.tick()
		loaded.tick()
		_expect(world.state_hash() == loaded.state_hash(),
			"the unloaded source and its mid-chain restore must keep matching state_hash() every tick while driven identically")
		if not completed and loaded.get_construction_sites().is_empty():
			completed = true
	_expect(completed, "a save/load taken mid-chain must not truncate it: every remaining site must still complete")
	_expect(world.get_construction_sites().is_empty(),
		"the uninterrupted source, driven identically, must also finish every remaining site")
	_expect(not InventoryType.is_carrying(loaded._find_colonist("colonist_0")),
		"hands must be empty once the reloaded chain finishes")
	_expect(String(loaded._scheduler.queue.get_job(job_id).get("status", "")) == "completed",
		"the SAME job that was mid-chain before save/load must be the one that serves every remaining destination, not a replacement")
	_expect(_pick_up_count(world) == pick_ups_before_load,
		"the uninterrupted source must not need any additional pick_up either: the remaining sites come from the material already in hands")
	_expect(_pick_up_count(loaded) == 0,
		"no additional pick_up may occur after loading: the restore's fresh trace must record zero, since the remaining sites come from the material already in hands at load time")

## Regression (round-1 review, issue #451): retarget_site_fetch_site() used to
## move an active job onto a sibling site with no capacity check at all, so a
## sibling already holding its own max_builders' worth of committed fetch/work
## jobs could receive one more anyway. Site B is driven to its own cap (1, a
## one-quantity wall block's max_builders) by a directly-injected competing
## fetch job BEFORE colonist_0's job ever reaches its own deposit-time chain
## decision, proving the capacity check applies at retarget time, not only at
## ConstructionGiver's submission time (which never sees a retarget at all).
func _check_chain_never_retargets_onto_a_sibling_already_at_its_own_capacity() -> void:
	var world := _build_world(451800)
	world._colonists.append(_colonist("colonist_0", 0, 0))
	_command_ok(world, "zone", "zone_add", {"x": 0, "y": 0, "width": 1, "height": 1})
	_add_stock(world, "wood", 2, 0, 0)
	var pos_a := Vector2i(10, 10)
	var pos_b := Vector2i(11, 10)
	var result := _command_ok(world, "line", "build_line", {"kind": "wooden_wall", "tiles": _tiles_from([pos_a, pos_b])})
	_expect((result.get("sites", []) as Array).size() == 2, "the fixture line must create 2 sites: %s" % result)
	_expect(_reach_hands_loaded_before_any_delivery(world, "wood", 2, [pos_a, pos_b]),
		"setup must reach hands carrying both units before any site has received material")
	# Occupies site B's own single max_builders slot with an unrelated fetch
	# job before colonist_0 ever delivers to A -- mirrors a second colonist
	# already committed to B by the time this chain would otherwise reach it.
	world._submit_site_fetch(pos_b, "stub_competing_item", Vector2i(0, 0), world.get_tick())
	var job_id := _active_site_fetch_job_id(world)
	_expect(not job_id.is_empty(), "colonist_0's own active site_fetch job must be found before it delivers")
	var completed := false
	for _i in MAX_TICKS:
		world.tick()
		if job_id.is_empty():
			break
		if String(world._scheduler.queue.get_job(job_id).get("status", "")) == "completed":
			completed = true
			break
	_expect(completed, "the job must complete rather than retarget onto a sibling already at its own capacity")
	_expect(not InventoryType.is_carrying(world._find_colonist("colonist_0")),
		"no material may remain stranded in hands once the job completes")
	var site_b := world.get_construction_site(pos_b.x, pos_b.y)
	_expect(not site_b.is_empty() and _held_quantity(site_b, "wood") == 0,
		"site B must never receive material through the excluded retarget: %s" % site_b)
	_expect(_total_ground_kind(world, "wood") == 1,
		"the 1 leftover unit must be dropped on the ground, not destroyed or silently delivered")

## Regression (round-1 review, issue #451): ending a chain used to call
## _finish_job() directly even while hands still held leftover material,
## stranding it there forever (nothing else ever drains "hands" once a job is
## terminal). Cancelling every remaining site in the chain while the colonist
## still carries the full hands-load reproduces the reviewer's exact scenario:
## pick up for 4 blocks, lose 3 destinations before ever delivering, then
## deposit to the one that remains.
func _check_cancelling_future_destinations_mid_chain_drops_leftover_and_completes() -> void:
	var world := _build_world(451900)
	world._colonists.append(_colonist("colonist_0", 0, 0))
	_command_ok(world, "zone", "zone_add", {"x": 0, "y": 0, "width": 1, "height": 1})
	_add_stock(world, "wood", 4, 0, 0)
	var positions: Array[Vector2i] = [Vector2i(10, 10), Vector2i(11, 10), Vector2i(12, 10), Vector2i(13, 10)]
	var result := _command_ok(world, "line", "build_line", {"kind": "wooden_wall", "tiles": _tiles_from(positions)})
	_expect((result.get("sites", []) as Array).size() == 4, "the fixture line must create 4 sites: %s" % result)
	_expect(_reach_hands_loaded_before_any_delivery(world, "wood", 4, positions),
		"setup must reach hands carrying all 4 units before any site has received material")
	var job_id := _active_site_fetch_job_id(world)
	_expect(not job_id.is_empty(), "colonist_0's own active site_fetch job must be found before its destinations are cancelled")
	for i in range(1, 4):
		_command_ok(world, "cancel_%d" % i, "cancel_site", {"x": positions[i].x, "y": positions[i].y})
	var completed := false
	for _i in MAX_TICKS:
		world.tick()
		if String(world._scheduler.queue.get_job(job_id).get("status", "")) == "completed":
			completed = true
			break
	_expect(completed, "the job must complete once its only surviving site is served, cancelled siblings notwithstanding")
	_expect(not InventoryType.is_carrying(world._find_colonist("colonist_0")),
		"no material may remain stranded in hands once the job completes")
	var site_0 := world.get_construction_site(positions[0].x, positions[0].y)
	_expect(not site_0.is_empty() and _held_quantity(site_0, "wood") == 1,
		"site 1 must have received exactly its own 1 unit of wood: %s" % site_0)
	_expect(_total_ground_kind(world, "wood") == 3,
		"the 3 units that lost their destinations must be dropped on the ground, not destroyed (exact conservation: 1 built + 3 dropped = 4)")

## Regression (round-1 review, issue #451): the same stranding defect as
## above, reached through legitimate competition instead of cancellation --
## "competing deliveries that satisfy the remaining sites produce the same
## failure" (round-1 review). Sites 2-4 are driven to fully-met directly
## (mirroring a competing colonist's own deliveries landing first) after
## colonist_0's hands are already sized and loaded for all 4, but before its
## own first deposit -- proving the leftover-drop path fires regardless of
## HOW the remaining sites stopped being eligible.
func _check_competing_deliveries_that_satisfy_remaining_sites_drop_leftover_and_complete() -> void:
	var world := _build_world(452000)
	world._colonists.append(_colonist("colonist_0", 0, 0))
	_command_ok(world, "zone", "zone_add", {"x": 0, "y": 0, "width": 1, "height": 1})
	_add_stock(world, "wood", 4, 0, 0)
	var positions: Array[Vector2i] = [Vector2i(10, 10), Vector2i(11, 10), Vector2i(12, 10), Vector2i(13, 10)]
	var result := _command_ok(world, "line", "build_line", {"kind": "wooden_wall", "tiles": _tiles_from(positions)})
	_expect((result.get("sites", []) as Array).size() == 4, "the fixture line must create 4 sites: %s" % result)
	_expect(_reach_hands_loaded_before_any_delivery(world, "wood", 4, positions),
		"setup must reach hands carrying all 4 units before any site has received material")
	var job_id := _active_site_fetch_job_id(world)
	_expect(not job_id.is_empty(), "colonist_0's own active site_fetch job must be found before the competing deliveries land")
	for i in range(1, 4):
		var site_id := String(world.get_construction_site(positions[i].x, positions[i].y)["id"])
		_expect(world._sites.deposit(site_id, "wood", 1) == 1, "the competing delivery to site %d must be accepted" % i)
	var completed := false
	for _i in MAX_TICKS:
		world.tick()
		if String(world._scheduler.queue.get_job(job_id).get("status", "")) == "completed":
			completed = true
			break
	_expect(completed, "the job must complete once every sibling is already satisfied by the competing deliveries")
	_expect(not InventoryType.is_carrying(world._find_colonist("colonist_0")),
		"no material may remain stranded in hands once the job completes")
	_expect(_total_ground_kind(world, "wood") == 3,
		"the 3 units this job never delivered must be dropped on the ground (exact conservation: 1 built by this job + 3 dropped = 4)")
