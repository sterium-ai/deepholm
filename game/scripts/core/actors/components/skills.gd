class_name ActorSkills
extends RefCounted

## Skills component (F3, ADR 062): a worker's top-level "skills" field, {labour: {"level", "xp"}}
## in the worker's declared labour order (state_hash() is key-order-sensitive). "xp" is the
## progress inside the current level and restarts at 0 on each level up; the top level keeps 0.
## The rules are content/skills.json (ContentRegistry.document("skills")), passed in by the
## caller. Invariants:
## - a labour the actor has no record for (forage, need jobs, a hand-built test actor) works at
##   base speed, earns no XP and adds no hands capacity: skills only scale what they track;
## - a bundle without skills.json (a test fixture) gives empty rules: base speed, no XP, no
##   bonus, no seeding; the base bundle always ships it;
## - no randomness here except seed_levels(), which draws only from the RNG it is handed.

## The rules document, or a frozen {} when the bundle has no skills.json.
static func rules(content: ContentRegistry) -> Dictionary:
	return content.document("skills")

## The top level: the length of xp_to_next (0 without rules).
static func max_level(skill_rules: Dictionary) -> int:
	var thresholds: Array = skill_rules.get("xp_to_next", [])
	return thresholds.size()

## Every labour at level 0, XP 0, in the given order.
static func build_zero(labours: Array) -> Dictionary:
	var skills: Dictionary = {}
	for labour: String in labours:
		skills[labour] = {"level": 0, "xp": 0}
	return skills

## True when actor carries a skill record for labour.
static func tracks(actor: Dictionary, labour: String) -> bool:
	var skills: Variant = actor.get("skills")
	return skills is Dictionary and (skills as Dictionary).has(labour)

## actor's level in labour; 0 when untracked.
static func level_of(actor: Dictionary, labour: String) -> int:
	if not tracks(actor, labour):
		return 0
	var record: Dictionary = actor["skills"][labour]
	var level: int = record["level"]
	return level

## Work speed in percent at `level`: linear from speed_percent_at_min (level 0) to
## speed_percent_at_max (the top level), rounded down; 100 without rules.
static func speed_percent(skill_rules: Dictionary, level: int) -> int:
	var top := max_level(skill_rules)
	if top <= 0:
		return 100
	var at_min: int = skill_rules["speed_percent_at_min"]
	var at_max: int = skill_rules["speed_percent_at_max"]
	return at_min + floori(float((at_max - at_min) * clampi(level, 0, top)) / float(top))

## The work toil's duration for actor on a job of `labour` whose kind declares base_ticks:
## base_ticks * 100 / speed, rounded to the nearest tick and never below 1. Untracked labours
## (and empty rules) keep base_ticks.
static func work_ticks_for(skill_rules: Dictionary, actor: Dictionary, labour: String, base_ticks: int) -> int:
	if skill_rules.is_empty() or not tracks(actor, labour):
		return base_ticks
	var speed := speed_percent(skill_rules, level_of(actor, labour))
	return maxi(1, roundi(float(base_ticks * 100) / float(speed)))

## Hands capacity (ADR 037's HANDS_CAPACITY) plus one unit per carry_bonus_every levels of
## carry_labour.
static func hands_capacity(skill_rules: Dictionary, actor: Dictionary, base_capacity: int) -> int:
	if skill_rules.is_empty():
		return base_capacity
	var carry_labour: String = skill_rules["carry_labour"]
	var every: int = skill_rules["carry_bonus_every"]
	return base_capacity + floori(float(level_of(actor, carry_labour)) / float(every))

## XP one completed job of `kind` earns: xp_per_job.by_kind[kind], else xp_per_job.default.
static func xp_for_kind(skill_rules: Dictionary, kind: String) -> int:
	if skill_rules.is_empty():
		return 0
	var xp_per_job: Dictionary = skill_rules["xp_per_job"]
	var by_kind: Dictionary = xp_per_job["by_kind"]
	var xp: int = by_kind.get(kind, xp_per_job["default"])
	return xp

## Adds `amount` XP to actor's labour, levelling up while the XP meets xp_to_next[level]
## (the remainder carries over); the top level gains nothing. No-op for an untracked labour.
static func award(skill_rules: Dictionary, actor: Dictionary, labour: String, amount: int) -> void:
	if amount <= 0 or skill_rules.is_empty() or not tracks(actor, labour):
		return
	var record: Dictionary = actor["skills"][labour]
	var thresholds: Array = skill_rules["xp_to_next"]
	var level: int = record["level"]
	if level >= thresholds.size():
		return
	var xp: int = record["xp"]
	xp += amount
	while level < thresholds.size():
		var needed: int = thresholds[level]
		if xp < needed:
			break
		xp -= needed
		level += 1
	record["level"] = level
	record["xp"] = 0 if level >= thresholds.size() else xp

## Overwrites labour's level (XP restarts at 0): a scenario roster's fixed starting skill.
static func set_level(actor: Dictionary, labour: String, level: int) -> void:
	if tracks(actor, labour):
		actor["skills"][labour] = {"level": level, "xp": 0}

## Seeded starting levels for one worker, in `labours` order: starting.major_count distinct
## labours at major_min..major_max, the rest at minor_min..minor_max. Draw order is fixed: the
## majors first (an index into the labours not yet drawn), then one level per labour in order.
static func seed_levels(skill_rules: Dictionary, labours: Array, random: RandomNumberGenerator) -> Dictionary:
	var skills := build_zero(labours)
	if skill_rules.is_empty():
		return skills
	var starting: Dictionary = skill_rules["starting"]
	var major_count: int = starting["major_count"]
	var remaining: Array = labours.duplicate()
	var majors: Dictionary = {}
	for _pick in mini(major_count, remaining.size()):
		var index := random.randi_range(0, remaining.size() - 1)
		var drawn: String = remaining[index]
		majors[drawn] = true
		remaining.remove_at(index)
	var top := max_level(skill_rules)
	var low_key := "minor_min"
	var high_key := "minor_max"
	for labour: String in labours:
		low_key = "major_min" if majors.has(labour) else "minor_min"
		high_key = "major_max" if majors.has(labour) else "minor_max"
		var low: int = starting[low_key]
		var high: int = starting[high_key]
		var record: Dictionary = skills[labour]
		record["level"] = clampi(random.randi_range(low, high), 0, top)
	return skills

## The viewer's per-labour row: {labour: {"level", "xp", "next"}}, "next" the XP the current
## level needs (0 at the top level).
static func progress(skill_rules: Dictionary, actor: Dictionary) -> Dictionary:
	var rows: Dictionary = {}
	var skills: Variant = actor.get("skills")
	if not (skills is Dictionary):
		return rows
	var thresholds: Array = skill_rules.get("xp_to_next", [])
	var records: Dictionary = skills
	for labour: String in records.keys():
		var record: Dictionary = records[labour]
		var level: int = record["level"]
		var xp: int = record["xp"]
		var next: int = 0
		if level < thresholds.size():
			next = thresholds[level]
		rows[labour] = {"level": level, "xp": xp, "next": next}
	return rows
