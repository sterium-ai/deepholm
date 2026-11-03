class_name ActorThoughts
extends RefCounted

## Thoughts and happiness (F5c, ADR 066): a colonist's optional top-level "thoughts" field, a
## list of {"id", "until"} sorted by id then until (state_hash() is order-sensitive). A thought
## is active while the clock tick is below its "until". Happiness is derived, never stored:
## base + the weights of the active thoughts, clamped to min..max. The rules are
## content/thoughts.json (ContentRegistry.document("thoughts")), passed in by the caller.
## Invariants:
## - only colonists (actors whose definition has the "worker" component) think;
## - the key is absent when the list is empty, so a colonist that never thought saves as before;
## - an id the rules do not define is never added and weighs nothing;
## - a bundle without thoughts.json (a test fixture) gives empty rules: no thought, happiness 50;
## - no randomness and no clock of its own: every function takes the tick it is evaluated at.

const ActorTableType = preload("res://scripts/core/actors/actor_table.gd")

const DEFAULT_BASE := 50

## The rules document, or a frozen {} when the bundle has no thoughts.json.
static func rules(content: ContentRegistry) -> Dictionary:
	return content.document("thoughts")

## True when actor keeps thoughts: its definition has the "worker" component (colonists; wolves
## and traders do not).
static func applies(actor: Dictionary, registry: ContentRegistry) -> bool:
	return ActorTableType.has_component(actor, "worker", registry)

## The thought's definition, or {} when the rules do not define id.
static func definition(thought_rules: Dictionary, id: String) -> Dictionary:
	for entry: Dictionary in thought_rules.get("thoughts", []):
		var entry_id: String = entry["id"]
		if entry_id == id:
			return entry
	return {}

## The ids of the thoughts a completed job of job_kind adds, in table order.
static func ids_for_job_kind(thought_rules: Dictionary, job_kind: String) -> Array[String]:
	var ids: Array[String] = []
	for entry: Dictionary in thought_rules.get("thoughts", []):
		if (entry.get("job_kinds", []) as Array).has(job_kind):
			var entry_id: String = entry["id"]
			ids.append(entry_id)
	return ids

## The thought's length in ticks: duration_days of a day_length_ticks day, at least 1.
static func duration_ticks(entry: Dictionary, day_length_ticks: int) -> int:
	var days: float = entry["duration_days"]
	return maxi(1, roundi(days * float(day_length_ticks)))

## Adds thought id to actor at tick now. "refresh" restarts its one instance; "stack" adds an
## instance up to stack_limit, then restarts the instance that expires first. No-op for an
## undefined id or an actor that does not think.
static func add(actor: Dictionary, id: String, thought_rules: Dictionary, now: int, day_length_ticks: int,
		registry: ContentRegistry) -> void:
	var entry := definition(thought_rules, id)
	if entry.is_empty() or not applies(actor, registry):
		return
	var until := now + duration_ticks(entry, day_length_ticks)
	var repeat: String = entry["repeat"]
	var limit := 1
	if repeat != "refresh":
		limit = entry["stack_limit"]
	var list: Array = actor.get("thoughts", [])
	var same: Array[int] = []
	for i in list.size():
		var record: Dictionary = list[i]
		if _id_of(record) == id and _until_of(record) > now:
			same.append(i)
	if same.size() >= limit:
		list[same[0]] = {"id": id, "until": until}
	else:
		list.append({"id": id, "until": until})
	_store(actor, list, now)

## Drops actor's expired thoughts (until <= now); removes the key when none is left.
static func prune(actor: Dictionary, now: int) -> void:
	if actor.has("thoughts"):
		var list: Array = actor["thoughts"]
		_store(actor, list, now)

## Happiness at tick now: base + the active thoughts' weights, clamped to min..max.
static func happiness(actor: Dictionary, thought_rules: Dictionary, now: int) -> int:
	var total: int = thought_rules.get("base", DEFAULT_BASE)
	for record: Dictionary in actor.get("thoughts", []):
		if _until_of(record) > now:
			total += _weight_of(thought_rules, _id_of(record))
	var low: int = thought_rules.get("min", 0)
	var high: int = thought_rules.get("max", 100)
	return clampi(total, low, high)

## The active thoughts for the viewer, in stored order: [{id, weight, remaining}], remaining in
## ticks until the instance expires.
static func active(actor: Dictionary, thought_rules: Dictionary, now: int) -> Array:
	var rows: Array = []
	for record: Dictionary in actor.get("thoughts", []):
		if _until_of(record) > now:
			var id := _id_of(record)
			rows.append({"id": id, "remaining": _until_of(record) - now,
				"weight": _weight_of(thought_rules, id)})
	return rows

## Once per tick from NeedsSystem.decay_needs()'s colonist loop, after the needs decayed: drops
## expired thoughts, then refreshes "hungry" while the food need is at or below its threshold
## and "slept_ground" while rest is at or below its threshold and no bed is reachable.
## bed_reachable is a Callable(actor) -> bool (a bed reachable from that actor's region), called
## only when rest is low so the bed lookup runs only then.
static func apply_state_tick(actor: Dictionary, thought_rules: Dictionary, now: int, day_length_ticks: int,
		bed_reachable: Callable, registry: ContentRegistry) -> void:
	if not applies(actor, registry) or thought_rules.is_empty():
		return
	prune(actor, now)
	var needs_component: Variant = ActorTableType.get_component(actor, "needs", registry)
	var needs: Dictionary = needs_component if needs_component != null else {}
	var hungry_rule: Dictionary = thought_rules.get("hungry", {})
	if _need_at_or_below(needs, hungry_rule):
		add(actor, "hungry", thought_rules, now, day_length_ticks, registry)
	var ground_rule: Dictionary = thought_rules.get("slept_ground", {})
	if _need_at_or_below(needs, ground_rule):
		var bed: bool = bed_reachable.call(actor)
		if not bed:
			add(actor, "slept_ground", thought_rules, now, day_length_ticks, registry)

static func _need_at_or_below(needs: Dictionary, rule: Dictionary) -> bool:
	if rule.is_empty():
		return false
	var need: String = rule["need"]
	if not needs.has(need):
		return false
	var value: int = needs[need]
	var threshold: int = rule["at_or_below"]
	return value <= threshold

static func _id_of(record: Dictionary) -> String:
	var id: String = record["id"]
	return id

static func _until_of(record: Dictionary) -> int:
	var until: int = record["until"]
	return until

static func _weight_of(thought_rules: Dictionary, id: String) -> int:
	var weight: int = definition(thought_rules, id).get("weight", 0)
	return weight

## Keeps the active records sorted by id then until; erases the key when none is active.
static func _store(actor: Dictionary, list: Array, now: int) -> void:
	var kept: Array = []
	for record: Dictionary in list:
		if _until_of(record) > now:
			kept.append(record)
	if kept.is_empty():
		actor.erase("thoughts")
		return
	kept.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return _id_of(a) < _id_of(b) if _id_of(a) != _id_of(b) else _until_of(a) < _until_of(b))
	actor["thoughts"] = kept
