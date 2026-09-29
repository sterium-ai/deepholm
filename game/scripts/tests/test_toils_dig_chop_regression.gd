extends SceneTree

## Regression for issue #190: dig/chop now execute through the generic toil
## executor (game/scripts/core/jobs/toil_executor.gd) instead of the
## kind-specific branches previously inlined in WorldState's
## _start_assignment/_advance_route/_start_work/_advance_work
## (colonist-ai.md 3.3). EXPECTED_HASH is a literal captured from this exact
## scripted run; an unchanged hash across a change to WorldState/ToilExecutor
## proves route/work stepping, MOVE_TICKS_PER_TILE/WORK_TICKS, and rerouting
## stayed behaviorally identical. Issue #192 updated this literal twice,
## deliberately: once because chop's completion effect switched from
## incrementing a per-tile ground-wood counter to spawning a first-class
## wood item, and again because state_hash() started including
## next_item_id in its snapshot. Issue #193 updated it again because
## state_hash() started including the (here always-empty) zones dict --
## again a snapshot-shape change, not a dig/chop stepping change. Issue #194
## updated it once more: WorldState now auto-submits one haul job per
## unreserved ground item every tick, so chop's wood spawns a queued haul job
## that shows up in get_jobs()/the scheduling snapshot (this scenario draws
## no stockpile zone, so every such job stays permanently
## blocked_destination_full and never touches a colonist's route/work) --
## again a snapshot-shape change, not a dig/chop stepping change. Issue #201
## updated it once more: every colonist's snapshot now carries a
## content-declared "needs" object (food/water/rest) that decays a tick at a
## time -- again a snapshot-shape change, not a dig/chop stepping change.
## Issue #207 updated it once more: every colonist's snapshot now also
## carries a "labourTable" object (mine/chop/farm/haul/build/craft/cook,
## colonist-ai.md 3.2) -- again a snapshot-shape change, not a dig/chop
## stepping change. Issue #213 updated it once more: state_hash() now
## includes the (here always-empty) toolItems/toolReservations maps and
## every colonist's held_tool field -- again a snapshot-shape change, not a
## dig/chop stepping change. Issue #241 updated it once more: the scheduler
## snapshot now carries a "restrictTo" field on every queue entry and a
## (here always-empty) "activatedEntries" map, added so a critical-need
## interrupt can put a job back in the queue with its aging preserved --
## again a snapshot-shape change, not a dig/chop stepping change. Issue #269
## updated it once more: state_hash() now includes the (here always-empty)
## calendar_alerts_fired set, added so a fired sowing-window alert never
## re-fires after a save/load round trip -- again a snapshot-shape change,
## not a dig/chop stepping change. Issue #271 updated it once more, and this
## time the scenario itself changed: dig/chop now declare needs_tool and a
## fetch_tool toil, so _build_world() spawns a pick and an axe at each
## colonist's own starting tile (picked up in one extra tick per colonist
## before its first dig/chop, then held and reused for every later job of the
## same kind) -- a real stepping change this time, not just a snapshot shape.
## Issue #271 round 5 updated it once more: the scheduler's own activation
## route search and ToilExecutor's fetch_tool travel now share one
## per-colonist per-tick routing allowance (ADR 004), so a colonist whose job
## activates the same tick fetch_tool would otherwise also want to resume its
## own (here trivial, distance-zero) travel search now defers that resume to
## the following tick -- a real one-tick stepping shift for this scenario's
## two colonists' very first dig/chop, not just a snapshot shape. Issue #271
## round 6 updated it once more: state_hash() now includes the (here
## always-empty, both dig/chop targets are reachable and each colonist's own
## pick/axe already held) tool_fetch_excluded map -- again a snapshot-shape
## change, not a dig/chop stepping change. Issue #283 updated it once more:
## every colonist's snapshot now also carries a "health" object (hp/maxHp/dead)
## -- again a snapshot-shape change, not a dig/chop stepping change. Issue
## #284 updated it once more: every colonist's snapshot now also carries a
## "factionId" string field -- again a snapshot-shape change, not a dig/chop
## stepping change. Issue #287 added a faction_id default for every placed
## object/item, but deliberately as a parallel map state_hash() does not
## snapshot (a save/load round trip cannot restore it yet -- t3), so this
## literal is unaffected. Issue #294 (ADR 015 Amendment) leaves it unaffected
## too: an "autonomous" queue-entry flag exists only on an incident actor's
## own submission (stored, snapshotted and saved only when true), so a world
## that never submits one -- this scenario, and every world with incidents
## disabled -- keeps its exact pre-#294 snapshot shape and this literal is
## the genuine pre-#294 baseline. Issue #299 round 1 updated it once more:
## state_hash() now includes the live world's own width/height, so two
## restored states with identical tiles/entities but different rectangular
## dimensions can no longer alias to the same hash -- again a snapshot-shape
## change, not a dig/chop stepping change. Issue #295 updated it once more:
## state_hash() now includes the incident scheduler's own (here
## always-empty, this world never enables incidents) cooldown-until-day map,
## last-processed-day and its independent RNG stream's seed/state -- again a
## snapshot-shape change, not a dig/chop stepping change. COLONY_EXPECTED_HASH
## is the value EXPECTED_HASH itself held before Issue #295 (the genuine
## pre-incident colony-only formula): state_hash(false) excludes the entire
## incidents contribution, so it stays this exact literal forever regardless
## of future incident-shape changes -- test_incidents.gd's own
## _check_disabled_reproduces_pre_incident_hash() and
## test_world_state_determinism.gd's own
## _check_incidents_disabled_matches_pre_incident_baseline() both rely on it
## as their independent, unchanging pre-incident baseline (ADR 004). This
## scenario never isolates needs (no _isolate_need() call), so both literals
## also moved for issue #349/ADR 023: needs.json's per-tick "rate" became a
## far slower per-day "rate_per_day", so the six colonists' needs barely move
## across TOTAL_TICKS now (where the old per-tick rate could previously have
## crossed a threshold and triggered a NeedGiver interrupt) -- a real stepping
## change, not just the accompanying "needsAccumulator" snapshot-shape
## addition every colonist's entry now also carries. Issue #358 (ADR 025,
## `docs/decisions/025-trench-trapped-actor-and-rescue.md`) updated both
## literals once more, and this time both are real stepping/shape changes:
## dig's target tile now becomes `trench`, not `floor`, and dig always spawns
## a ground `sand` item plus rolls a seeded find_table draw (this scenario's
## four dig orders each consume one roll from `WorldState._dig_find_random`)
## -- new tiles, new items and a new RNG stream's contribution to observable
## state that pre-#358 hashes never accounted for. Issue #358 round 2 review
## updated both literals once more, a pure snapshot-shape change this time:
## state_hash() now also includes `_dig_find_random`'s own seed/state (so the
## save-load persistence this round adds is actually covered by the
## diagnostic hash, matching the incident scheduler's own RNG precedent) --
## COLONY_EXPECTED_HASH moves too since this field is unconditional, not
## gated by state_hash()'s own include_incidents parameter. Issue #359 (ADR
## 025 t3) updated both literals once more: every colonist's snapshot now
## also carries a "trapped" field (a snapshot-shape change), and the
## fixture's geometry moved row 1 to row 2 with a one-tile rock buffer at
## y=1 separating the two corridors (see _build_world()'s own comment) --
## with the corridors connected as they were pre-#359, a colonist assigned
## to a farther target under the fair scheduler's nearest/priority ordering
## could path diagonally back across a row-mate's already-dug trench tile
## and fall in, so the buffer is the fixture-geometry adaptation the new
## trap-on-entry rule needs. Assignment, tool placement, priority and haul
## are otherwise UNCHANGED from before #359: both colonists still start
## holding neither tool with a pick and an axe on the ground at each start
## tile, every dig/chop order is still unrestricted (no "assignee", the fair
## scheduler still picks whichever colonist is free -- now trivially the one
## in the reachable row -- and each colonist still does both a dig and a
## chop on its own row, so it still swaps pick/axe), priorities still vary
## (every dig is now priority 2, every chop priority 1 -- see
## _run_scenario()'s own comment for why), and haul stays enabled. Route search
## still treats trench as ordinary passable terrain; only the arrival check
## added by #359 is what this geometry now avoids triggering by accident --
## a different scenario exercises trap-on-entry on purpose
## (test_trapped_actors.gd). Both literals were recaptured from this exact
## scripted run. Issue #278/#303 (docs/decisions/027) updated both literals
## once more, again a pure snapshot-shape change: every job dict (dig/chop
## included, not only build) now carries "site"/"build_kind" fields
## (job_queue.gd's own native build-only fields, mirroring item_id/cell's
## existing always-present shape), so state_hash()'s "jobs" entry changes for
## every job kind even though no dig/chop stepping behaviour changed at all.
## Issue #360 (ADR 025 t4, rescue_giver.gd) updated both literals once more, a
## pure snapshot-shape change: state_hash() now also includes RescueGiver's
## own job_id -> victim_id association ("rescue_victim_assignments"),
## unconditionally like the dig-find RNG stream above -- always empty here
## (no colonist in this scenario ever falls into a trench), but the new key
## itself still changes the dict shape both hashes are computed over. Its
## round-4 review (finding 3) moved both literals once more, again a pure
## shape change: that field is now hashed in state_codec.gd's own sorted
## {jobId, victimId} array encoding (an empty Array here) rather than the raw
## Dictionary (an empty Dictionary), so a save/load that restores identical
## associations in a different insertion order hashes identically. Merging
## issue #360 onto origin/main (both the "site"/"build_kind" job fields above
## and the rescue-victim-assignments field landing together for the first
## time) moved both literals once more -- a pure combined snapshot-shape
## change, recaptured by running this test under Godot.

const WorldType = preload("res://scripts/core/world_state.gd")
const ToilExecutorType = preload("res://scripts/core/jobs/toil_executor.gd")
const JOBS_CONTENT_PATH := "res://content/jobs.json"

## Issue #302: colonist now carries a real "combat" component
## (content/actors.json), backfilled by WorldState._ensure_combat() the
## first tick any colonist exists -- a genuine, intentional snapshot-shape
## change (like issue #295's incident-scheduler fields before it), plus
## state_hash() including world._object_health (round-3 review: a wall/door's
## accumulated damage must be hash-visible) and CombatGiver's own
## excluded-flee-destination set (round-6 review, second pass:
## `_blocked_targets` affects the very next flee-destination pick, so a
## determinism comparison that differs only in it must not hash equal) --
## each a genuine, intentional shape change to the same snapshot dict,
## present even here where no actor in this scripted run ever fights, is
## damaged or flees, since each new key itself changes the dict shape. This
## merge (origin/main's #358 dig-find-roll/trench/sand additions) moved both
## literals again, and the #359 merge below (colonist "trapped" field) moves
## them once more. Issue #278/#303 round 6 (second pass) added
## "suspended_work_progress" to the same snapshot dict (a suspended job's own
## progress affects what happens the moment it resumes, so two states
## differing only in it must not hash equal) -- present even here (an empty
## array) since the new key itself changes the dict shape, moving both
## literals once more. Issue #390 (ADR 031, ApproachGiver) adds
## "approach_job_targets" to the same snapshot dict, unconditionally like the
## fields above -- always empty here (this scenario never spawns a hostile
## actor), but the new key itself still moves both literals once more. ADR
## 031 round-2 review finding 2 adds "approach_retired_actors" to the same
## snapshot dict for the same reason, moving both literals once more. Issue
## #391 removes "approach_retired_actors" again (ApproachGiver no longer
## retires an actor permanently -- see approach_giver.gd's own class doc
## comment), moving both literals a final time. Issue #402 (ADR 035) moves
## both literals once more: a colonist's single-slot "carrying" field becomes
## "hands", a list instead of a nullable object -- a pure snapshot-shape
## change (empty here, since no colonist in this scenario ever carries
## anything), not a dig/chop stepping change.
## Issue #406 (ADR 038) moves both literals once more: state_hash() now also
## includes "construction_sites" (ConstructionSiteTable.list()), unconditionally
## like every other giver's own association above -- always empty here (this
## scenario never issues a `build` command), but the new key itself still
## changes the dict shape.
## Regenerated by running this test under Godot, per AGENTS.md's "never
## hand-derive a hash" rule.
const EXPECTED_HASH := 1457403841
const COLONY_EXPECTED_HASH := 828510519
const TOTAL_TICKS := 260

var _failed := false

func _init() -> void:
	_check_jobs_content_file()

	var world := _build_world(190190)
	_run_scenario(world)
	var ticks := 0
	while ticks < TOTAL_TICKS:
		world.tick()
		ticks += 1

	var completed := 0
	for job in world.get_jobs():
		if job["status"] == "completed":
			completed += 1
	_expect(completed == 6, "all six scripted dig/chop orders must complete within the fixed tick budget (got %d)" % completed)
	for colonist in world._colonists:
		_expect(colonist.get("trapped") == null,
			"no colonist should be trapped by the end of this scenario (got %s on %s)" % [colonist.get("trapped"), colonist["id"]])

	var hash_value := world.state_hash()
	_expect(hash_value == EXPECTED_HASH,
		"state_hash() must match the literal captured before the toils refactor (got %d, expected %d)" % [hash_value, EXPECTED_HASH])
	var colony_hash_value := world.state_hash(false)
	_expect(colony_hash_value == COLONY_EXPECTED_HASH,
		"state_hash(false)'s colony-only projection must match the unchanging pre-incident baseline (got %d, expected %d)" % [colony_hash_value, COLONY_EXPECTED_HASH])

	if _failed:
		quit(1)
		return
	print("test_toils_dig_chop_regression: PASS")
	quit(0)

func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failed = true
		push_error(message)

## game/content/jobs.json must parse as JSON and declare exactly the dig,
## mine, chop, forage, till, sow, haul, site_fetch, site_work, eat_food,
## drink_water, sleep, incident, escape_trench, flee, rescue and approach
## kinds, each with a toils
## array using only the vocabulary names from colonist-ai.md 3.3 (reserve,
## go_to, pick_up, work, place, consume, fetch_tool, release_all).
func _check_jobs_content_file() -> void:
	var file := FileAccess.open(JOBS_CONTENT_PATH, FileAccess.READ)
	if file == null:
		_expect(false, "could not open %s" % JOBS_CONTENT_PATH)
		return
	var parsed = JSON.parse_string(file.get_as_text())
	file.close()
	_expect(typeof(parsed) != TYPE_NIL, "%s must parse as JSON" % JOBS_CONTENT_PATH)
	if typeof(parsed) != TYPE_DICTIONARY or typeof(parsed.get("jobs")) != TYPE_ARRAY:
		_expect(false, "%s must contain a top-level 'jobs' array" % JOBS_CONTENT_PATH)
		return
	var kinds: Dictionary = {}
	for entry in parsed["jobs"]:
		_expect(typeof(entry) == TYPE_DICTIONARY, "every jobs.json entry must be an object")
		if typeof(entry) != TYPE_DICTIONARY:
			continue
		var kind := String(entry.get("kind", ""))
		kinds[kind] = true
		_expect(typeof(entry.get("toils")) == TYPE_ARRAY and not (entry["toils"] as Array).is_empty(),
			"%s toils must be a non-empty array" % kind)
		for toil in entry.get("toils", []):
			_expect(ToilExecutorType.is_known_toil(String(toil)),
				"%s declares unknown toil '%s'" % [kind, toil])
	_expect(kinds.size() == 17 and kinds.has("dig") and kinds.has("mine") and kinds.has("chop") and kinds.has("forage") and kinds.has("till")
			and kinds.has("sow") and kinds.has("haul") and kinds.has("site_fetch") and kinds.has("site_work") and kinds.has("eat_food") and kinds.has("drink_water") and kinds.has("sleep")
			and kinds.has("incident") and kinds.has("escape_trench") and kinds.has("flee") and kinds.has("rescue") and kinds.has("approach"),
		"jobs.json must declare exactly the dig, mine, chop, forage, till, sow, haul, site_fetch, site_work, eat_food, drink_water, sleep, incident, escape_trench, flee, rescue and approach kinds (got %s)" % [kinds.keys()])

func _command(world: WorldType, command_id: String, kind: String, payload: Dictionary) -> Dictionary:
	return world.apply({"actor": "test", "command_id": command_id, "tick": world.get_tick(),
		"type": kind, "payload": payload})

## Two parallel corridors (y=0, y=2; x=0..9) with a tree at the far end of
## each row and a one-tile rock buffer (y=1) between them; everything else is
## rock. Two colonists start at the near end of each row so dig/chop targets,
## routing and the fair scheduler (unrestricted "assignee") all have real
## work to do -- each colonist does both a dig and a chop order on its own
## row, so it still swaps between pick and axe. Issue #359: the buffer row
## makes the two corridors physically unreachable from one another, which is
## the fixture-geometry adaptation the new trap-on-entry rule needs -- with
## the corridors connected (as they briefly were before #359, y=0/y=1
## adjacent), a colonist assigned to a farther target under the fair
## scheduler's nearest/priority ordering could path diagonally back across a
## row-mate's already-dug trench tile and fall in, which is exactly what
## test_trapped_actors.gd exists to cover on purpose; this scenario's own
## point is dig/chop/toil stepping, so its geometry is adapted to never
## trigger that here instead of restricting assignment to dodge it.
func _build_world(seed_value: int) -> WorldType:
	var world := WorldType.new(seed_value)
	world._tiles.fill(WorldType.TILE_ROCK)
	# issue #300: clear any generator-placed berry_bush (docs/decisions/020)
	# before overwriting tiles -- a stray one would leak into state_hash()
	# even though it cannot affect this fixture's own two corridors, breaking
	# the literal EXPECTED_HASH/COLONY_EXPECTED_HASH captured before this
	# task existed for a reason unrelated to what either literal documents.
	world._objects.clear()
	world._object_factions.clear()
	for x in range(0, 10):
		world._tiles[world._tile_index(x, 0)] = WorldType.TILE_SOIL
		world._tiles[world._tile_index(x, 2)] = WorldType.TILE_SOIL
	world._tiles[world._tile_index(9, 0)] = WorldType.TILE_TREE
	world._tiles[world._tile_index(9, 2)] = WorldType.TILE_TREE
	world._colonists.clear()
	world._colonists.append({"id": "colonist_0", "kind": "colonist", "x": 0, "y": 0, "route": null, "work": null})
	world._colonists.append({"id": "colonist_1", "kind": "colonist", "x": 0, "y": 2, "route": null, "work": null})
	# Axe sits past every dig target (x=8, just short of the tree at x=9),
	# pick at the start (x=0, before every dig target) -- see _run_scenario()'s
	# own comment for why this placement, combined with its priorities, keeps
	# every fetch_tool trip and every dig/chop leg strictly forward, so no
	# colonist ever re-lands on a trench tile it (or nothing else, these rows
	# are unreachable from one another) already dug.
	world.spawn_ground_tool_item("pick", 0, 0)
	world.spawn_ground_tool_item("axe", 8, 0)
	world.spawn_ground_tool_item("pick", 0, 2)
	world.spawn_ground_tool_item("axe", 8, 2)
	return world

## Submits a scripted sequence of dig and chop orders, ticking between
## submissions so some orders are still queued/blocked when the next lands --
## exercising reserve/go_to/work/release_all across overlapping jobs, not
## just one job at a time. Unrestricted (no "assignee"): the fair scheduler
## picks whichever colonist is free/nearest, same as before #359. Priority
## still varies (every dig outranks every chop, 2 vs 1) -- issue #359: this
## is deliberately chosen, not merely preserved, so that within a row every
## dig is always served before that row's chop regardless of submission
## order/aging (global_assignment.gd's PRIORITY_WEIGHT=16 dwarfs this
## scenario's few-tick submission spread), and dig_1/dig_2/dig_4 (equal
## priority, so FIFO by submission order/ordinal) are served in strictly
## ascending x. A colonist therefore always walks its row purely rightward
## -- pick already in hand from its first dig, straight through 3, 5, 7 --
## and only afterwards, once, forward again to the axe depot at 8 and the
## tree at 9: no dig target is ever revisited after the trap-on-entry rule
## turns it to trench.
func _run_scenario(world: WorldType) -> void:
	_command(world, "dig_1", "dig", {"x": 3, "y": 0, "priority": 2})
	_command(world, "dig_2", "dig", {"x": 5, "y": 0, "priority": 2})
	world.tick()
	world.tick()
	_command(world, "chop_1", "chop", {"x": 9, "y": 0, "priority": 1})
	_command(world, "dig_3", "dig", {"x": 3, "y": 2, "priority": 2})
	world.tick()
	world.tick()
	world.tick()
	_command(world, "chop_2", "chop", {"x": 9, "y": 2, "priority": 1})
	_command(world, "dig_4", "dig", {"x": 7, "y": 0, "priority": 2})
