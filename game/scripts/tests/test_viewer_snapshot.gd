extends SceneTree

## A9 (ADR 054): WorldState.get_view_snapshot() and the viewer that reads it.
## 1) the snapshot agrees with the getters it replaces (get_colonists(),
##    get_actors_with_health(), get_job(), get_colonist_need_reason(), ...), is
##    read-only all the way down, and is a copy: ticking the world never changes it;
## 2) the sprite layers keep no node per actor (one _draw() per layer);
## 3) the colonist panel keeps its row nodes across refreshes, recomposes at most
##    ROWS_PER_REFRESH lines per refresh, and still reaches every row in turn;
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

func _init() -> void:
	_check_snapshot_matches_getters()
	_check_snapshot_is_frozen_copy()
	_check_layers_keep_no_nodes()
	_check_panel_rows_rotate()
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

func _check_panel_rows_rotate() -> void:
	var count := ColonistPanelType.ROWS_PER_REFRESH * 2 + 5
	var world := BenchCommon.world_with_colonists(7, 48, 48, count)
	var panel := ColonistPanelType.new()
	panel.setup(world, TextTableType.new())
	var list: VBoxContainer = panel._list
	_expect(list.get_child_count() == count, "one row per colonist (%d, got %d)" % [count, list.get_child_count()])
	var first_row := list.get_child(0)
	for row in list.get_children():
		(row as Label).text = "stale"
	var refreshes := ceili(float(count) / ColonistPanelType.ROWS_PER_REFRESH)
	for i in refreshes:
		panel.refresh()
		var fresh := 0
		for row in list.get_children():
			if (row as Label).text != "stale":
				fresh += 1
		_expect(fresh <= (i + 1) * ColonistPanelType.ROWS_PER_REFRESH,
			"refresh %d recomposes at most ROWS_PER_REFRESH lines (%d fresh)" % [i, fresh])
	for row in list.get_children():
		_expect((row as Label).text != "stale", "every row is recomposed within ceil(roster / ROWS_PER_REFRESH) refreshes")
	_expect(list.get_child(0) == first_row, "rows are updated in place, not rebuilt")
	var colonist := world.get_colonists()[0]
	_expect((list.get_child(0) as Label).text == panel._line_for(colonist), "a recomposed row shows _line_for()'s line")
	panel.free()

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
