extends SceneTree

## Invariants that were prose in the core's class docs (R16), checked through the public
## WorldState API on a busy world (chop/mine/dig orders and a stockpile, 300 ticks):
## - EventLog: get_events() is sorted by (tick, system_priority, entity_id, sequence) and
##   every sequence is unique.
## - Inventory (ADR 037): hands hold at most one entry per kind, every count >= 1, and the
##   total never exceeds HANDS_CAPACITY plus the colonist's haul-skill bonus (ADR 062), on
##   every tick.
## - Persistence: events are runtime-only and the retired-job history is neither persisted
##   nor hashed, so a save/load round trip keeps state_hash(), re-encodes to the same save,
##   starts with an empty event log and keeps the event sequence counter moving forward.

const WorldStateType = preload("res://scripts/core/world_state.gd")
const InventoryType = preload("res://scripts/core/actors/components/inventory.gd")
const SkillsType = preload("res://scripts/core/actors/components/skills.gd")

const SEED := 4242
const SIZE := 48
const TICKS := 300
const HALF := 24

var _failed := false
var _n := 0

func _init() -> void:
	var world := WorldStateType.new(SEED, 10, SIZE, SIZE)
	_issue_orders(world)
	for i in TICKS:
		world.tick()
		_check_hands(world)
	_check_event_order(world.get_events())
	_check_round_trip(world)

	if _failed:
		quit(1)
		return
	print("test_core_invariants: PASS")
	quit()

func _fail(message: String) -> void:
	push_error(message)
	_failed = true

func _apply(world: WorldStateType, type: String, payload: Dictionary) -> Dictionary:
	_n += 1
	return world.apply({"actor": "player", "command_id": "inv%d" % _n, "tick": world.get_tick(), "type": type, "payload": payload})

## Up to eight chop, six mine and six dig orders on matching tiles, plus a 3x3 stockpile
## on the first free soil block found; at least one order must be accepted.
func _issue_orders(world: WorldStateType) -> void:
	var wanted := {"tree": ["chop", 8], "rock": ["mine", 6], "soil": ["dig", 6]}
	var accepted := 0
	for y in SIZE:
		for x in SIZE:
			var kind := world.get_tile(x, y)
			if not wanted.has(kind) or int(wanted[kind][1]) <= 0:
				continue
			if _apply(world, String(wanted[kind][0]), {"x": x, "y": y, "priority": 1}).get("ok", false):
				accepted += 1
				wanted[kind][1] = int(wanted[kind][1]) - 1
	if accepted == 0:
		_fail("setup: no order was accepted")
	for y in range(HALF - 8, HALF + 8):
		for x in range(HALF - 8, HALF + 8):
			if _apply(world, "zone_add", {"x": x, "y": y, "width": 3, "height": 3}).get("ok", false):
				return

func _check_hands(world: WorldStateType) -> void:
	for colonist in world.get_colonists():
		var kinds: Dictionary = {}
		var total := 0
		for entry: Dictionary in (colonist.get("hands", []) as Array):
			var kind := String(entry.get("kind", ""))
			var count := int(entry.get("count", 0))
			if count < 1:
				_fail("tick %d: %s holds a count-%d entry of %s" % [world.get_tick(), colonist["id"], count, kind])
			if kinds.has(kind):
				_fail("tick %d: %s holds two %s entries" % [world.get_tick(), colonist["id"], kind])
			kinds[kind] = true
			total += count
		var capacity := SkillsType.hands_capacity(SkillsType.rules(TestAccess.content(world)), colonist, InventoryType.HANDS_CAPACITY)
		if total > capacity:
			_fail("tick %d: %s holds %d units, above its hands capacity %d" % [world.get_tick(), colonist["id"], total, capacity])

func _event_key(event: Dictionary) -> Array:
	return [int(event["tick"]), int(event["system_priority"]), String(event["entity_id"]), int(event["sequence"])]

func _check_event_order(events: Array[Dictionary]) -> void:
	if events.size() < 2:
		_fail("setup: expected a busy event log, got %d events" % events.size())
		return
	var sequences: Dictionary = {}
	for i in events.size():
		var sequence := int(events[i]["sequence"])
		if sequences.has(sequence):
			_fail("event sequence %d appears twice" % sequence)
		sequences[sequence] = true
		if i > 0:
			var before := _event_key(events[i - 1])
			var after := _event_key(events[i])
			if not _key_less(before, after):
				_fail("events %d and %d are out of order: %s then %s" % [i - 1, i, before, after])
				return

func _key_less(a: Array, b: Array) -> bool:
	for i in a.size():
		if a[i] != b[i]:
			return a[i] < b[i]
	return false

func _check_round_trip(world: WorldStateType) -> void:
	var save := world.to_save_state()
	var restored: WorldStateType = WorldStateType.from_save_state(save)
	if restored.state_hash() != world.state_hash():
		_fail("state_hash() changed across a save/load round trip: %d -> %d" % [world.state_hash(), restored.state_hash()])
	if JSON.stringify(restored.to_save_state()) != JSON.stringify(save):
		_fail("a reloaded world must re-encode to the same save")
	if not restored.get_events().is_empty():
		_fail("events are runtime-only: a reloaded world starts with an empty log, got %d" % restored.get_events().size())
	var last_sequence := 0
	for event in world.get_events():
		last_sequence = maxi(last_sequence, int(event["sequence"]))
	for i in 20:
		world.tick()
		restored.tick()
	if restored.state_hash() != world.state_hash():
		_fail("the original and the reloaded world diverged within 20 ticks")
	for event in restored.get_events():
		if int(event["sequence"]) <= last_sequence:
			_fail("a reloaded world reused event sequence %d (last before the save: %d)" % [int(event["sequence"]), last_sequence])
			return
