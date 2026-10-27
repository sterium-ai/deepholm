extends SceneTree

## A6: the event and dirty-cell logs as bounded cursor streams.
## - WorldState.get_events_since(): reading a real session incrementally, one
##   cursor per tick, yields exactly get_events() (same events, same order),
##   whole and filtered by type.
## - EventLog retention: past MAX_EVENTS the oldest events (in log order) go,
##   the per-type index stays equal to the filtered log, and a cursor that
##   missed dropped events reads back "truncated".
## - JobQueue (JobEventLog) retention: trimmed only at the start of tick(),
##   never mid-burst; get_events_since() reports truncation the same way.
## - TileGrid dirty-cell retention and get_dirty_cells_since().
## - Viewer consumers: map_view falls back to a full rebuild on a truncated
##   dirty-cell read; status_text keeps incident lines after their event was
##   trimmed, and restarts for another world.

const WorldStateType = preload("res://scripts/core/world_state.gd")
const EventLogType = preload("res://scripts/core/world/event_log.gd")
const QueueType = preload("res://scripts/core/jobs/job_queue.gd")
const JobEventLogType = preload("res://scripts/core/jobs/job_event_log.gd")
const TileGridType = preload("res://scripts/core/map/tile_grid.gd")
const MapViewType = preload("res://scripts/viewer/map_view.gd")
const StatusTextType = preload("res://scripts/viewer/status_text.gd")
const TextTableType = preload("res://scripts/viewer/text_table.gd")

var _failed := false
var _n := 0

func _init() -> void:
	_check_incremental_read_equals_full_log()
	_check_event_log_retention()
	_check_job_queue_retention()
	_check_dirty_cell_retention()
	_check_map_view_full_rebuild_on_truncation()
	_check_status_text_keeps_trimmed_incidents()
	if _failed:
		quit(1)
		return
	print("test_event_streams: PASS")
	quit()

func _cmd(world: WorldStateType, type: String, payload: Dictionary) -> Dictionary:
	_n += 1
	return {"actor": "player", "command_id": "s%d" % _n, "tick": world.get_tick(), "type": type, "payload": payload}

func _check_incremental_read_equals_full_log() -> void:
	var world := WorldStateType.new(777, 10, 48, 48, true)
	var rng := RandomNumberGenerator.new()
	rng.seed = 4242
	var cursor := 0
	var typed_cursor := 0
	var read: Array[Dictionary] = []
	var typed_read: Array[Dictionary] = []
	var types := ["tick_advanced", "command_rejected", "job_queued"]
	for t in 300:
		if t % 25 == 0:
			for k in 4:
				var kind: String = ["dig", "chop", "forage", "till", "mine"][rng.randi_range(0, 4)]
				world.apply(_cmd(world, kind, {"x": rng.randi_range(0, 47), "y": rng.randi_range(0, 47), "priority": 1}))
			world.apply(_cmd(world, "bogus", {}))
		if t == 60:
			world.apply(_cmd(world, "spawn_incident", {"id": "trader_visit"}))
		if t == 120:
			world.apply(_cmd(world, "spawn_incident", {"id": "wolf_attack"}))
		world.tick()
		var stream: Dictionary = world.get_events_since(cursor)
		_expect(not bool(stream["truncated"]), "tick %d: a %d-event session must never truncate" % [t, world.get_events().size()])
		var chunk: Array = stream["events"]
		for i in range(1, chunk.size()):
			_expect(_log_less(chunk[i - 1], chunk[i]), "tick %d: one read must list its events in log order" % t)
		read.append_array(chunk)
		cursor = int(stream["next"])
		var typed: Dictionary = world.get_events_since(typed_cursor, types)
		typed_read.append_array(typed["events"])
		typed_cursor = int(typed["next"])
	var full := world.get_events()
	_expect(full.size() > 300, "setup: the session must record a real log, got %d events" % full.size())
	# A read returns the events new since its cursor, in log order; a later one
	# can still sort before an event already read (a command applied at tick T
	# orders before tick T's tick_advanced), so the reads merged back into log
	# order must be the log itself.
	read.sort_custom(_log_less)
	typed_read.sort_custom(_log_less)
	_expect(read == full, "per-tick get_events_since() reads must merge to get_events() (%d vs %d events)" % [read.size(), full.size()])
	_expect(typed_read == world.get_events(types), "per-tick typed reads must merge to get_events(types)")
	var again: Dictionary = world.get_events_since(cursor)
	_expect((again["events"] as Array).is_empty() and int(again["next"]) == cursor, "a read at the head cursor must return nothing new")
	var copy: Dictionary = world.get_events_since(0)
	(copy["events"] as Array)[0]["type"] = "mutated"
	_expect(world.get_events()[0]["type"] != "mutated", "get_events_since() must return deep copies")

## EventLog's own order: (tick, system_priority, entity_id, sequence).
static func _log_less(a: Dictionary, b: Dictionary) -> bool:
	if a["tick"] != b["tick"]:
		return a["tick"] < b["tick"]
	if a["system_priority"] != b["system_priority"]:
		return a["system_priority"] < b["system_priority"]
	if a["entity_id"] != b["entity_id"]:
		return a["entity_id"] < b["entity_id"]
	return a["sequence"] < b["sequence"]

func _insert(log: EventLogType, clock: SeededClock, type: String) -> void:
	log.insert_event({"type": type, "tick": clock.tick, "system_priority": 0, "entity_id": "world",
		"sequence": log.next_sequence(), "data": {}})

func _check_event_log_retention() -> void:
	var clock := SeededClock.new(1)
	var log := EventLogType.new(clock, QueueType.new(RandomNumberGenerator.new(), Callable()), 0)
	var max_size := 0
	for i in EventLogType.MAX_EVENTS + 1000:
		if i % 7 == 0:
			clock.tick += 1
		_insert(log, clock, "even" if i % 2 == 0 else "odd")
		max_size = maxi(max_size, log.size())
	_expect(max_size <= EventLogType.MAX_EVENTS, "the event log must never hold more than %d events, peaked at %d" % [EventLogType.MAX_EVENTS, max_size])
	var full := log.get_events()
	_expect(full.size() == log.size() and full.size() >= EventLogType.RETAINED_EVENTS,
		"after a trim at least RETAINED_EVENTS must stay, got %d" % full.size())
	_expect(int(full[-1]["sequence"]) == EventLogType.MAX_EVENTS + 999, "the newest event must survive a trim")
	_expect(int(full[0]["sequence"]) > 0, "the oldest events must be the ones dropped")
	for type in ["even", "odd"]:
		var filtered: Array[Dictionary] = []
		for event in full:
			if event["type"] == type:
				filtered.append(event)
		_expect(log.get_events([type]) == filtered, "after a trim get_events([%s]) must still equal the filtered log" % type)
	var oldest_kept := int(full[0]["sequence"])
	var old: Dictionary = log.get_events_since(0)
	_expect(bool(old["truncated"]), "a cursor behind dropped events must read back truncated")
	_expect(old["events"] == full, "a truncated read still returns every retained event")
	var fresh: Dictionary = log.get_events_since(oldest_kept + 1)
	_expect(not bool(fresh["truncated"]) and (fresh["events"] as Array).size() == full.size() - 1,
		"a cursor past every dropped event must not be truncated and must miss nothing")
	_expect(int(fresh["next"]) == EventLogType.MAX_EVENTS + 1000, "next must be the next sequence to draw")
	log.decode({"eventSequence": 5, "queueEventSequence": -1})
	_expect(log.size() == 0 and not bool(log.get_events_since(0)["truncated"]), "decode() must restart the log and its retention state")

func _check_job_queue_retention() -> void:
	var queue := QueueType.new(RandomNumberGenerator.new(), Callable())
	var burst := JobEventLogType.MAX_EVENTS + 500
	for i in burst:
		queue._emit("job_test", "job_%d" % i, {})
	_expect(queue.get_events().size() == burst, "a burst must be kept whole until the next tick()")
	_expect(not bool(queue.get_events_since(0)["truncated"]), "nothing is dropped mid-burst")
	queue.tick()
	var events := queue.get_events()
	_expect(events.size() == JobEventLogType.RETAINED_EVENTS, "tick() must trim to RETAINED_EVENTS, got %d" % events.size())
	_expect(int(events[0]["sequence"]) == burst - JobEventLogType.RETAINED_EVENTS, "the trim must drop the oldest events")
	var stream := queue.get_events_since(0)
	_expect(bool(stream["truncated"]) and int(stream["next"]) == queue.get_sequence(), "an old cursor must read back truncated, next = get_sequence()")
	var tail := queue.get_events_since(burst - 10)
	_expect(not bool(tail["truncated"]) and tail["events"] == events.slice(events.size() - 10), "a recent cursor must read the exact tail")
	_expect(queue.get_events_after(burst - 11) == tail["events"], "get_events_since(s) must equal get_events_after(s - 1)")
	queue.tick()
	_expect(queue.get_events().size() == JobEventLogType.RETAINED_EVENTS, "a log under MAX_EVENTS is not trimmed again")

func _check_dirty_cell_retention() -> void:
	var grid := TileGridType.new(8, 8, Callable(), Callable(), Callable())
	var cursor := 0
	var max_size := 0
	var total := TileGridType.MAX_DIRTY_CELLS + 700
	for i in total:
		grid.mark_dirty(i % 8, (i / 8) % 8)
		max_size = maxi(max_size, grid.dirty_cells.size())
	_expect(max_size <= TileGridType.MAX_DIRTY_CELLS, "the dirty-cell log must never exceed %d, peaked at %d" % [TileGridType.MAX_DIRTY_CELLS, max_size])
	var all: Dictionary = grid.get_dirty_cells_since(cursor)
	_expect(bool(all["truncated"]) and int(all["next"]) == total, "a cursor behind dropped cells must read back truncated, next = %d" % total)
	var recent: Dictionary = grid.get_dirty_cells_since(total - 3)
	var expected: Array[Vector2i] = []
	for i in range(total - 3, total):
		expected.append(Vector2i(i % 8, (i / 8) % 8))
	_expect(not bool(recent["truncated"]) and recent["cells"] == expected, "a recent cursor must read exactly the newest cells, got %s" % [recent["cells"]])
	_expect((grid.get_dirty_cells_since(total)["cells"] as Array).is_empty(), "a read at the head returns no cells")

func _check_map_view_full_rebuild_on_truncation() -> void:
	var world := WorldStateType.new(31, 10, 32, 32)
	var map_view := MapViewType.new()
	root.add_child(map_view)
	map_view.set_art_enabled(true)
	map_view.set_world(world)
	var full_count := map_view.last_tile_map_cells_touched
	world.tick()
	map_view.refresh()
	_expect(map_view.last_tile_map_cells_touched == 0, "setup: a tick with no change touches no cell")
	world._tile_grid.mark_dirty(3, 3)
	map_view.refresh()
	_expect(map_view.last_tile_map_cells_touched == 1, "one dirty cell must touch one cell, got %d" % map_view.last_tile_map_cells_touched)
	for i in TileGridType.MAX_DIRTY_CELLS + 1:
		world._tile_grid.mark_dirty(i % 32, (i / 32) % 32)
	map_view.refresh()
	_expect(map_view.last_tile_map_cells_touched == full_count,
		"a truncated dirty-cell read must rebuild every cell (%d), got %d" % [full_count, map_view.last_tile_map_cells_touched])
	map_view.refresh()
	_expect(map_view.last_tile_map_cells_touched == 0, "after the rebuild the cursor is at the head again")
	map_view.queue_free()

func _check_status_text_keeps_trimmed_incidents() -> void:
	var world := WorldStateType.new(41, 10, 16, 16)
	var text_table := TextTableType.new()
	world._event_log.insert_event({"type": "incident_started", "tick": world.get_tick(), "system_priority": 0,
		"entity_id": "world", "sequence": world._event_log.next_sequence(), "data": {"incident_id": "raid_1", "faction": "wolves"}})
	var line := "Incident: raid_1 (wolves)"
	_expect(StatusTextType.need_alerts_text(world, text_table).find(line) >= 0, "setup: the incident line must show")
	var clock: SeededClock = world._clock
	for i in EventLogType.MAX_EVENTS + 1:
		_insert(world._event_log, clock, "filler")
	_expect(world.get_events(["incident_started"]).is_empty(), "setup: retention must have dropped the incident event")
	var text := StatusTextType.need_alerts_text(world, text_table)
	_expect(text.count(line) == 1, "an incident line must survive its event's retention, once, got '%s'" % text)
	var other := WorldStateType.new(42, 10, 16, 16)
	_expect(StatusTextType.need_alerts_text(other, text_table).find(line) == -1, "another world must not inherit the first world's incident lines")

func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failed = true
		push_error(message)
