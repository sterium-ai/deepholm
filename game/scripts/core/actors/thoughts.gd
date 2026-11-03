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
static func applies(actor: Dictionary, registry) -> bool:
	return ActorTableType.has_component(actor, "worker", registry)

## The thought's definition, or {} when the rules do not define id.
static func definition(thought_rules: Dictionary, id: String) -> Dictionary:
	for entry: Dictionary in thought_rules.get("thoughts", []):
		if String(entry["id"]) == id:
			return entry
	return {}

## The ids of the thoughts a completed job of job_kind adds, in table order.
static func ids_for_job_kind(thought_rules: Dictionary, job_kind: String) -> Array[String]:
	var ids: Array[String] = []
	for entry: Dictionary in thought_rules.get("thoughts", []):
		if (entry.get("job_kinds", []) as Array).has(job_kind):
			ids.append(String(entry["id"]))
	return ids

## The thought's length in ticks: duration_days of a day_length_ticks day, at least 1.
static func duration_ticks(entry: Dictionary, day_length_ticks: int) -> int:
	return maxi(1, roundi(float(entry["duration_days"]) * float(day_length_ticks)))

## Adds thought id to actor at tick now. "refresh" restarts its one instance; "stack" adds an
## instance up to stack_limit, then restarts the instance that expires first. No-op for an
## undefined id or an actor that does not think.
static func add(actor: Dictionary, id: String, thought_rules: Dictionary, now: int, day_length_ticks: int,
		registry) -> void:
	var entry := definition(thought_rules, id)
	if entry.is_empty() or not applies(actor, registry):
		return
	var until := now + duration_ticks(entry, day_length_ticks)
	var limit := 1 if String(entry["repeat"]) == "refresh" else int(entry["stack_limit"])
	var list: Array = actor.get("thoughts", [])
	var same: Array[int] = []
	for i in list.size():
		if String(list[i]["id"]) == id and int(list[i]["until"]) > now:
			same.append(i)
	if same.size() >= limit:
		# Instances of one id stay sorted by until, so the first is the one that expires first.
		list[same[0]] = {"id": id, "until": until}
	else:
		list.append({"id": id, "until": until})
	_store(actor, list, now)

## Drops actor's expired thoughts (until <= now); removes the key when none is left.
static func prune(actor: Dictionary, now: int) -> void:
	if actor.has("thoughts"):
		_store(actor, actor["thoughts"], now)

## Happiness at tick now: base + the active thoughts' weights, clamped to min..max.
static func happiness(actor: Dictionary, thought_rules: Dictionary, now: int) -> int:
	var total := int(thought_rules.get("base", DEFAULT_BASE))
	for record: Dictionary in actor.get("thoughts", []):
		if int(record["until"]) > now:
			total += int(definition(thought_rules, String(record["id"])).get("weight", 0))
	return clampi(total, int(thought_rules.get("min", 0)), int(thought_rules.get("max", 100)))

## The active thoughts for the viewer, in stored order: [{id, weight, remaining}], remaining in
## ticks until the instance expires.
static func active(actor: Dictionary, thought_rules: Dictionary, now: int) -> Array:
	var rows: Array = []
	for record: Dictionary in actor.get("thoughts", []):
		if int(record["until"]) > now:
			rows.append({"id": String(record["id"]), "remaining": int(record["until"]) - now,
				"weight": int(definition(thought_rules, String(record["id"])).get("weight", 0))})
	return rows

## Once per tick from NeedsSystem.decay_needs()'s colonist loop, after the needs decayed: drops
## expired thoughts, then refreshes "hungry" while the food need is at or below its threshold
## and "slept_ground" while rest is at or below its threshold and no bed is reachable.
## bed_reachable is a Callable() -> bool so the bed lookup runs only when rest is low.
static func apply_state_tick(actor: Dictionary, thought_rules: Dictionary, now: int, day_length_ticks: int,
		bed_reachable: Callable, registry) -> void:
	if not applies(actor, registry) or thought_rules.is_empty():
		return
	prune(actor, now)
	var needs_component: Variant = ActorTableType.get_component(actor, "needs", registry)
	var needs: Dictionary = needs_component if needs_component != null else {}
	if _need_at_or_below(needs, thought_rules.get("hungry", {})):
		add(actor, "hungry", thought_rules, now, day_length_ticks, registry)
	if _need_at_or_below(needs, thought_rules.get("slept_ground", {})) and not bool(bed_reachable.call()):
		add(actor, "slept_ground", thought_rules, now, day_length_ticks, registry)

static func _need_at_or_below(needs: Dictionary, rule: Dictionary) -> bool:
	if rule.is_empty() or not needs.has(String(rule["need"])):
		return false
	return int(needs[String(rule["need"])]) <= int(rule["at_or_below"])

## Keeps the active records sorted by id then until; erases the key when none is active.
static func _store(actor: Dictionary, list: Array, now: int) -> void:
	var kept: Array = []
	for record: Dictionary in list:
		if int(record["until"]) > now:
			kept.append(record)
	if kept.is_empty():
		actor.erase("thoughts")
		return
	kept.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return String(a["id"]) < String(b["id"]) if String(a["id"]) != String(b["id"]) else int(a["until"]) < int(b["until"]))
	actor["thoughts"] = kept
