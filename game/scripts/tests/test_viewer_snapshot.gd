extends SceneTree

## A9 (ADR 055): WorldState.get_view_snapshot() and the viewer that reads it.
## 1) the snapshot agrees with the getters it replaces (get_colonists(),
##    get_actors_with_health(), get_job(), get_colonist_need_reason(), ...), is
##    read-only all the way down, and is a copy: ticking the world never changes it;
## 2) the sprite layers keep no node per actor (one _draw() per layer);
## 3) the colonist panel keeps its row nodes across refreshes; on a tick it recomposes
##    at most ROWS_PER_REFRESH lines plus the rows on screen, and still reaches every
##    row in turn; a refresh at the same tick (a command, also while paused)
##    recomposes every row;
## 4) TickDriver runs at most MAX_TICKS_PER_FRAME ticks per frame and drops the rest
##    of a long frame's backlog.

const WorldStateType = preload("res://scripts/core/world_state.gd")
const DebugScenario = preload("res://scripts/viewer/debug_scenario.gd")
const BenchCommon = preload("res://scripts/tests/bench_common.gd")
const ColonistSpritesType = preload("res://scripts/viewer/colonist_sprites.gd")
const ActorSpritesType = preload("res://scripts/viewer/actor_sprites.gd")
const ColonistPanelType = preload("res://scripts/viewer/colonist_panel.gd")
const TextTableType = preload("res://scripts/viewer/text_table.gd")
const TickDriverType = preload("res://scripts/viewer/tick_driver.gd")
const PackAssetsType = preload("res://scripts/viewer/pack_assets.gd")

var _failed := false

func _initialize() -> void:
	_run.call_deferred()

## Deferred so the tree runs frames: the on-screen-rows check needs real layout.
func _run() -> void:
	_check_snapshot_matches_getters()
	_check_snapshot_is_frozen_copy()
	_check_layers_keep_no_nodes()
	_check_panel_rows_rotate()
	_check_paused_command_refreshes_every_row()
	await _check_rows_on_screen_refresh_every_tick()
	_check_tick_driver_cap()
	if _failed:
		quit(1)
		return
	print("test_viewer_snapshot: PASS")
	quit(0)

func _expect(condition: bool, message: String) -> void:
	if not condition:
		push_error(message)
		_failed = true

## A debug-scenario world a few ticks in (dig orders under way), plus a wolf so
## the snapshot holds a non-worker actor with health.
func _busy_world() -> WorldStateType:
	var world := DebugScenario.build(null, null, true)
	var spawned := world.apply({"actor": "test", "command_id": "wolf", "tick": world.get_tick(), "type": "spawn_incident",
		"payload": {"id": "wolf_attack"}})
	_expect(spawned["ok"], "setup: the wolf incident spawns (%s)" % [spawned])
	for _i in 30:
		world.tick()
	return world

func _check_snapshot_matches_getters() -> void:
	var world := _busy_world()
	var colonists := world.get_colonists()
	var ids: Array = []
	for colonist in colonists:
		ids.append(String(colonist["id"]))
	var snapshot := world.get_view_snapshot(ids)
	_expect(int(snapshot["tick"]) == world.get_tick(), "snapshot tick is the world's")
	var rows := {}
	var all_ids: PackedStringArray = snapshot["ids"]
	for row in all_ids.size():
		rows[all_ids[row]] = row
	var worker: PackedByteArray = snapshot["worker"]
	_expect(worker.count(1) == colonists.size(), "worker column marks exactly get_colonists()' roster")
	var tool_kinds := {}
	for tool_item in world.get_tool_items():
		tool_kinds[String(tool_item["id"])] = String(tool_item["kind"])
	for colonist in colonists:
		var id := String(colonist["id"])
		var row: int = rows.get(id, -1)
		_expect(row >= 0 and worker[row] == 1, "%s is a worker row" % id)
		if row < 0:
			continue
		_expect(PackedInt32Array(snapshot["x"])[row] == int(colonist["x"])
			and PackedInt32Array(snapshot["y"])[row] == int(colonist["y"]), "%s tile matches get_colonists()" % id)
		var carried: Variant = colonist["carrying"]
		_expect(PackedStringArray(snapshot["carrying"])[row] == (String(carried["kind"]) if carried != null else ""),
			"%s carrying column matches the carrying view" % id)
		_expect(PackedStringArray(snapshot["tool_kinds"])[row] == String(tool_kinds.get(String(colonist.get("held_tool", "")), "")),
			"%s tool kind matches its held tool item" % id)
		var work: Variant = colonist.get("work")
		var work_kind := String(world.get_job(String(work["job_id"]))["kind"]) if work != null else ""
		_expect(PackedStringArray(snapshot["work_kinds"])[row] == work_kind, "%s work kind matches get_job()" % id)
		_expect(snapshot["details"][id] == colonist, "%s detail equals its get_colonists() entry" % id)
		_expect(String((snapshot["need_reasons"] as Dictionary).get(id, "")) == world.get_colonist_need_reason(id),
			"%s need reason matches get_colonist_need_reason()" % id)
	var sorted_ids := PackedStringArray(ids)
	sorted_ids.sort()
	var by_id := PackedStringArray()
	for row in PackedInt32Array(snapshot["workers_by_id"]):
		by_id.append(all_ids[row])
	_expect(by_id == sorted_ids, "workers_by_id lists the roster sorted by id")
	var health_ids := {}
	for actor in world.get_actors_with_health():
		health_ids[String(actor["id"])] = true
		var row: int = rows.get(String(actor["id"]), -1)
		_expect(row >= 0 and PackedInt32Array(snapshot["hp"])[row] == int(actor["health"]["hp"]),
			"%s hp matches get_actors_with_health()" % actor["id"])
	_expect(PackedInt32Array(snapshot["hp"]).size() - PackedInt32Array(snapshot["hp"]).count(-1) == health_ids.size(),
		"hp >= 0 exactly for the actors with health")
	_expect(worker.has(0), "the scenario's wolf is a non-worker row")
	for job_id: String in snapshot["jobs"]:
		_expect(snapshot["jobs"][job_id] == world.get_job(job_id), "job %s equals get_job()" % job_id)
	_expect(snapshot["assignments"] == world.get_assignments(), "assignments equal get_assignments()")
	_expect(snapshot["items"] == world.get_items() and snapshot["zones"] == world.get_zones()
		and snapshot["construction_sites"] == world.get_construction_sites(), "map collections equal their getters")
	var none := world.get_view_snapshot()
	_expect((none["details"] as Dictionary).is_empty(), "no detail_ids -> no full records")
	_expect(world.get_view_snapshot(["no_such_actor"])["details"].is_empty(), "an unknown detail id is skipped")

func _check_snapshot_is_frozen_copy() -> void:
	var world := _busy_world()
	var id := String(world.get_colonists()[0]["id"])
	var snapshot := world.get_view_snapshot([id])
	var detail: Dictionary = snapshot["details"][id]
	_expect(snapshot.is_read_only(), "the snapshot is read-only")
	_expect(detail.is_read_only() and (detail["needs"] as Dictionary).is_read_only()
		and (detail["labourTable"] as Dictionary).is_read_only() and (detail["hands"] as Array).is_read_only(),
		"a detail and its nested containers are read-only")
	_expect((snapshot["details"] as Dictionary).is_read_only() and (snapshot["need_reasons"] as Dictionary).is_read_only()
		and (snapshot["assignments"] as Dictionary).is_read_only() and (snapshot["items"] as Array).is_read_only(),
		"the snapshot's collections are read-only")
	for column in ["ids", "kinds", "factions", "x", "y", "worker", "carrying", "tool_kinds", "trapped", "work_kinds",
			"hp", "max_hp", "workers_by_id"]:
		_expect(snapshot[column] is Array and (snapshot[column] as Array).is_read_only(),
			"column %s is a read-only Array (a Packed*Array would be shared by reference)" % column)
	var kept := detail.duplicate(true)
	var xs: PackedInt32Array = snapshot["x"]
	var kept_xs := xs.duplicate()
	xs[0] = -99 # a packed column is a value: this write reaches neither the snapshot nor the world
	_expect(PackedInt32Array(snapshot["x"]) == kept_xs, "writing a column's copy leaves the snapshot unchanged")
	for _i in 20:
		world.tick()
	_expect(snapshot["details"][id] == kept, "ticking the world leaves an earlier snapshot unchanged")
	_expect(TestAccess.find_colonist(world, id)["x"] != -99, "no column write reached the simulation")

func _check_layers_keep_no_nodes() -> void:
	var world := _busy_world()
	var sprites := ColonistSpritesType.new()
	sprites.set_world(world)
	world.tick()
	sprites.refresh()
	_expect(sprites.get_child_count() == 0, "colonist layer keeps no node per colonist (has %d)" % sprites.get_child_count())
	_expect(sprites._sprites.size() == world.get_colonists().size(), "one body record per colonist")
	sprites.free()
	var actors := ActorSpritesType.new(PackAssetsType.actor_frames())
	actors.set_world(world)
	actors.refresh()
	_expect(actors.get_child_count() == 0, "actor layer keeps no node per actor")
	actors.free()

## A world of ROWS_PER_REFRESH * 2 + 5 colonists, several of them working till orders.
func _panel_world() -> WorldStateType:
	var world := BenchCommon.world_with_colonists(7, 64, 64, ColonistPanelType.ROWS_PER_REFRESH * 2 + 5)
	BenchCommon.submit_till_orders(world, world.get_colonists().size())
	for _i in 6:
		world.tick()
	return world

func _mark_stale(list: VBoxContainer) -> void:
	for row in list.get_children():
		(row as Label).text = "stale"

func _fresh_count(list: VBoxContainer) -> int:
	var fresh := 0
	for row in list.get_children():
		if (row as Label).text != "stale":
			fresh += 1
	return fresh

func _check_panel_rows_rotate() -> void:
	var world := _panel_world()
	var count := world.get_colonists().size()
	var panel := ColonistPanelType.new()
	panel.setup(world, TextTableType.new())
	var list: VBoxContainer = panel._list
	_expect(list.get_child_count() == count, "one row per colonist (%d, got %d)" % [count, list.get_child_count()])
	var first_row := list.get_child(0)
	_mark_stale(list)
	var refreshes := ceili(float(count) / ColonistPanelType.ROWS_PER_REFRESH)
	for i in refreshes:
		world.tick()
		panel.refresh()
		var fresh := _fresh_count(list)
		_expect(fresh <= (i + 1) * ColonistPanelType.ROWS_PER_REFRESH,
			"tick refresh %d recomposes at most ROWS_PER_REFRESH lines (%d fresh)" % [i, fresh])
	_expect(_fresh_count(list) == count, "every row is recomposed within ceil(roster / ROWS_PER_REFRESH) ticks")
	_expect(list.get_child(0) == first_row, "rows are updated in place, not rebuilt")
	panel.free()

## The reviewer's case: while paused (no tick), a command changes a colonist whose row
## is outside the window; the refresh that follows the command must show it.
func _check_paused_command_refreshes_every_row() -> void:
	var world := _panel_world()
	var panel := ColonistPanelType.new()
	panel.setup(world, TextTableType.new())
	world.tick()
	panel.refresh() # a tick refresh: only the window
	var window: Array = panel._window_ids([])
	var target := ""
	var assignments := world.get_assignments()
	for id: String in assignments:
		if not window.has(id):
			target = id
			break
	_expect(target != "", "setup: a working colonist outside the next window")
	if target == "":
		panel.free()
		return
	_expect(panel.detail_ids().size() == world.get_colonists().size(),
		"at the last refresh's tick, detail_ids() asks for every colonist")
	var row := panel._rows[target]["label"] as Label
	var before := row.text
	_mark_stale(panel._list)
	var job_id := String(assignments[target]["job_id"])
	var result := world.apply({"actor": "test", "command_id": "cancel_%s" % job_id, "tick": world.get_tick(),
		"type": "cancel_job", "payload": {"job_id": job_id}})
	_expect(result["ok"], "setup: cancel_job is accepted (%s)" % [result])
	panel.refresh() # same tick: a command's refresh
	_expect(_fresh_count(panel._list) == world.get_colonists().size(), "a same-tick refresh recomposes every row")
	_expect(row.text == panel._line_for(TestAccess.find_colonist(world, target)) and row.text != before,
		"the cancelled colonist's row (outside the window) shows its new state at once")
	panel.free()

## Rows inside the enclosing ScrollContainer's visible rect are recomposed on every
## tick refresh, even outside the window.
func _check_rows_on_screen_refresh_every_tick() -> void:
	var world := _panel_world()
	var scroll := ScrollContainer.new()
	scroll.size = Vector2(400, 300)
	var content := VBoxContainer.new()
	scroll.add_child(content)
	var panel := ColonistPanelType.new()
	panel.custom_minimum_size = Vector2(380, 20000)
	content.add_child(panel)
	root.add_child(scroll)
	panel.setup(world, TextTableType.new())
	for _i in 3:
		await process_frame
	scroll.scroll_vertical = 2000
	for _i in 3:
		await process_frame
	var on_screen: Array = panel._visible_ids()
	var window: Array = panel._window_ids([])
	_expect(not on_screen.is_empty(), "setup: some rows are on screen after scrolling")
	_expect(on_screen.any(func(id: String) -> bool: return not window.has(id)),
		"setup: an on-screen row lies outside the window (%s vs %s)" % [on_screen, window])
	_mark_stale(panel._list)
	world.tick()
	panel.refresh()
	for id: String in on_screen:
		_expect((panel._rows[id]["label"] as Label).text != "stale", "on-screen row %s is recomposed on a tick" % id)
	_expect(_fresh_count(panel._list) <= ColonistPanelType.ROWS_PER_REFRESH + on_screen.size(),
		"a tick refresh recomposes only the window and the on-screen rows")
	# Review round 2: paused (no tick, no command), scrolling elsewhere must not show a
	# line composed at an older tick.
	var tick := world.get_tick()
	for _i in 3:
		await process_frame # let the list lay out its recomposed rows before measuring one
	var far_row := panel._list.get_child(panel._roster.size() - 4) as Control
	scroll.scroll_vertical = int(far_row.position.y)
	for _i in 3:
		await process_frame
	var revealed: Array = panel._visible_ids().filter(func(id: String) -> bool: return not on_screen.has(id))
	_expect(not revealed.is_empty(), "setup: scrolling reveals other rows")
	_expect(world.get_tick() == tick, "setup: no tick while scrolling")
	var older := 0
	for id: String in revealed:
		var label := panel._rows[id]["label"] as Label
		if label.text == "stale":
			older += 1
		_expect(label.text == panel._line_for(TestAccess.find_colonist(world, id)),
			"row %s scrolled into view while paused shows the current line" % id)
		_expect(int(panel._composed_at.get(id, -1)) == tick, "row %s is marked composed at the current tick" % id)
	_expect(older == 0, "no row scrolled into view while paused is left stale (%d stale)" % older)
	scroll.queue_free()
	await process_frame

func _check_tick_driver_cap() -> void:
	var world := WorldStateType.new(5)
	var driver := TickDriverType.new(world)
	var ticks := [0]
	driver.ticked.connect(func() -> void: ticks[0] += 1)
	driver.set_speed(TickDriverType.Speed.X3)
	driver._process(10.0) # 60 ticks due at x3
	_expect(ticks[0] == TickDriverType.MAX_TICKS_PER_FRAME,
		"a long frame runs MAX_TICKS_PER_FRAME ticks, got %d" % ticks[0])
	driver._process(0.0)
	_expect(ticks[0] == TickDriverType.MAX_TICKS_PER_FRAME, "the dropped backlog does not run on the next frame")
	driver._process(0.2) # 1.2 ticks due at x3: one runs
	_expect(ticks[0] == TickDriverType.MAX_TICKS_PER_FRAME + 1, "ordinary frames still tick at the chosen speed")
	_expect(world.get_tick() == ticks[0], "every counted tick advanced the world")
	driver.free()
