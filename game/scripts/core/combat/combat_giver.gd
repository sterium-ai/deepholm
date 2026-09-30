class_name CombatGiver
extends RefCounted

## F5 job-giver for the flee decision (rule 4's "paths away" half):
## decides when a `flee` job should exist, exactly like HaulGiver/NeedGiver
## decide their own job's existence (AGENTS.md "one work engine" -- never a
## per-colonist loop, a re-route path, or a job-state machine of its own).
## Movement itself is the ordinary `go_to` toil once submitted; this module
## only ever calls into the same job_queue.gd entry points every other
## job-giver uses, via `WorldState._scheduler.submit_autonomous()` (ADR 014
## Amendment) so a non-colony combat actor (a hostile wolf) can flee its own
## job the same way an incident actor walks its own -- an ordinary
## `may_be_ordered`-gated `submit()` would refuse a wildlife-faction actor's
## own flee job outright.

const TargetingType = preload("res://scripts/core/combat/combat_targeting.gd")
const FLEE_KIND := "flee"
const FLEE_PRIORITY := 1
const FLEE_DISTANCE := 6

## The two blocked reasons JobQueue.tick() assigns a "queued" job that can
## never progress on its own: its target is already another job's reservation
## (BLOCKED_TARGET_RESERVED), or the scheduler's own coarse reachability check
## says it cannot be reached at all (BLOCKED_TARGET_UNREACHABLE) -- mirrors
## JobQueue's own string constants (a local copy of its typed-reason
## vocabulary, exactly like NeedGiver's own REASON_BLOCKED_SOURCE_RESERVED
## is).
const BLOCKED_TARGET_RESERVED := "blocked_target_reserved"
const BLOCKED_TARGET_UNREACHABLE := "blocked_target_unreachable"

## Ordered away from a threat's own dominant axis first (a single diagonal
## ray would leave an actor stuck whenever that one ray is blocked).
## Fixed array order backs the deterministic tie-break in _ranked_directions().
const CANDIDATE_DIRECTIONS: Array[Vector2i] = [
	Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1),
	Vector2i(1, 1), Vector2i(1, -1), Vector2i(-1, 1), Vector2i(-1, -1),
]

var _submit_job: Callable
var _get_job: Callable
var _list_jobs: Callable
var _restrict_to_for: Callable
var _interrupt: Callable
var _resume: Callable
var _passable_for_actor: Callable
var _may_reserve_target: Callable
var _reachable: Callable
var _bounds_max: Vector2i
var _content
var _relations
var _is_target_reserved: Callable
var _cancel_job: Callable

## actor_id -> the flee job_id currently pursued for it -- a giver-owned
## association, mirroring NeedGiver's own `_pending` map, never a field on the
## job record itself. Rebuilt from
## the scheduler's own queued/active jobs (see `_adopt_existing_flee_job()`
## and `restore_blocked_targets()`), never assumed to have survived a
## save/load: this Dictionary itself is never serialized, so a reload starts
## it empty even while a `flee` job it once tracked is still queued/active in
## state that did persist. Never the record of whether an actor is mid-flee:
## that is `_episodes` below, which outlives any individual leg.
var _fleeing: Dictionary = {}

## actor_id -> Dictionary[Vector2i, true]: the flee *episode* this giver owns
## for that actor, keyed by the actor and holding every
## destination a cancelled blocked flee job for it targeted during that
## episode. The key's presence, not any current flee job,
## is what says "this giver interrupted this actor's work and owns its
## recovery": it is opened at the exact moment `_interrupt` is called for the
## first leg, survives a blocked leg's cancellation, survives destination
## exhaustion (every candidate excluded, no replacement submitted, `_fleeing`
## empty), survives a save/load (this is the map state_codec.gd persists as
## `combatBlockedTargets` and state_hash() covers), and is closed only by
## recovery (advance()'s not-should_flee branch, which retires any flee job,
## clears these exclusions and resumes the interrupted work) or death
## (`forget()`). The excluded tiles themselves are skipped by every
## subsequent `_pick_flee_target()` call for the same actor so a fresh search
## never picks the identical tile straight back (a reservation that just lost
## the race, or a whole run of same-direction candidates that all sit past a
## faction-forbidden door the region-connectivity check cannot see through);
## they accumulate for as long as the episode continues -- a tile proven
## unreachable this episode stays excluded even after a different leg
## succeeds.
var _episodes: Dictionary = {}

## submit_job(target, priority, tick, kind, worker)->Dictionary must be
## WorldState._scheduler.submit_autonomous. get_job(job_id)->Dictionary must
## be WorldState._scheduler.queue.get_job. list_jobs()->Array[Dictionary] must
## be WorldState._scheduler.queue.get_jobs (used only to reconcile this
## giver's own association after a fresh load, never to drive per-tick
## decisions). restrict_to_for(job_id)->String must be
## WorldState._job_restricted_to (the raw
## WorldState._scheduler.restrict_to_for only knows an activated job; a
## queued or still-searching flee job restored from a save needs the
## fallback to the raw waiting-queue entry _job_restricted_to also provides,
## or a reload mid-flee submits a duplicate leg). interrupt(actor: Dictionary)->void
## must be WorldState._interrupt_current_job (the same critical-interrupt
## boundary NeedGiver uses, ADR 009) so a fleeing actor actually drops its
## current work/haul/travel instead of finishing it first. resume(actor_id:
## String)->void must be WorldState._resume_interrupted_job. passable_for_actor
## (actor_id, x, y)->Dictionary must be a faction-aware WorldState wrapper
## around passability() (a hostile actor's own faction, not "colony", decides
## whether a door blocks it). may_reserve_target(actor_id, target)->bool must
## be WorldState._actor_may_reserve_target (the same reservation-eligibility
## gate submit_autonomous()'s own reserve step consults, so a candidate this
## giver picks is never refused there for a reason it could have checked
## itself -- colony property for a hostile actor, a reserved cell, etc.).
## reachable(from, target)->bool must be a WorldState wrapper around
## RegionMap.reachable (region connectivity, not just single-tile
## passability, so a disconnected pocket is never picked). bounds_max is the
## map's own (width-1, height-1). content/relations are WorldState's own
## frozen ContentRegistry/Relations instances. is_target_reserved(x, y)->bool
## must be a WorldState wrapper around the shared
## ReservationTable (WorldState._flee_target_reserved) so a candidate already
## claimed by another job's own target reservation is never picked in the
## first place. cancel_job(job_id)->void must be
## WorldState._cancel_autonomous_job (the shared _finish_job() boundary) so a
## `flee` job stuck "queued" and blocked can be retired without waiting on
## _toil_on_unreachable(), which only ever fires once a job has activated.
## Also called on ordinary recovery (hp back
## above flee_hp_fraction) to retire a still-queued or still-active flee job
## before resuming interrupted work -- a no-op reject for a job already
## terminal (job_queue.gd's own _finish() status guard), so this is safe
## whether or not the job has already ended on its own.
func _init(submit_job: Callable, get_job: Callable, list_jobs: Callable, restrict_to_for: Callable,
		interrupt: Callable, resume: Callable, passable_for_actor: Callable, may_reserve_target: Callable,
		reachable: Callable, bounds_max: Vector2i, content, relations,
		is_target_reserved: Callable, cancel_job: Callable) -> void:
	_submit_job = submit_job
	_get_job = get_job
	_list_jobs = list_jobs
	_restrict_to_for = restrict_to_for
	_interrupt = interrupt
	_resume = resume
	_passable_for_actor = passable_for_actor
	_may_reserve_target = may_reserve_target
	_reachable = reachable
	_bounds_max = bounds_max
	_content = content
	_relations = relations
	_is_target_reserved = is_target_reserved
	_cancel_job = cancel_job

static func _flee_hp_fraction(actor: Dictionary, content) -> float:
	var definition: Dictionary = content.get_entry("actors", String(actor.get("kind", "")))
	var combat_tunables: Dictionary = (definition.get("tunables", {}) as Dictionary).get("combat", {})
	return float(combat_tunables.get("flee_hp_fraction", 0.0))

static func _hp_fraction(actor: Dictionary) -> float:
	var health: Dictionary = actor.get("health", {})
	var max_hp := maxi(1, int(health.get("maxHp", 1)))
	return float(int(health.get("hp", 0))) / float(max_hp)

## Drops any association this giver holds for actor_id -- called by
## WorldState on death, so a removed actor is never consulted for a status
## again (the job itself is cancelled through the shared finish boundary
## separately).
func forget(actor_id: String) -> void:
	_fleeing.erase(actor_id)
	_episodes.erase(actor_id)

## actor_id -> job_id for every actor this giver currently tracks as fleeing
## WorldState layers this over NeedGiver's own
## get_pending_assignments() before calling GlobalAssignment.tick(), the same
## `committed_needs` boundary a critical need already uses to force its own
## job past ordinary priority scoring -- otherwise a `flee` job merely sitting
## in the ordinary waiting queue can lose to a higher-scoring candidate (the
## work it just interrupted, re-entering the pool via suspend_assignment())
## forever, since CombatGiver itself never re-interrupts once `_fleeing`
## already names a tracked, non-terminal job.
func get_committed_jobs() -> Dictionary:
	return _fleeing.duplicate()

## True while this giver holds an open flee episode for actor_id: the same "this giver interrupted this actor's work and owns its
## recovery" test `_episodes.has()` already documents above -- broader than
## `_fleeing`, since an episode also stays open through destination
## exhaustion (no current job tracked) and across a save/load before
## restore_blocked_targets() re-adopts any surviving job. WorldState consults
## this to keep NeedGiver from touching an actor while this giver owns the
## shared interrupt/resume boundary for it.
func owns(actor_id: String) -> bool:
	return _episodes.has(actor_id)

## Every flee episode this giver currently owns, actor_id ->
## Dictionary[Vector2i, true] of its excluded destinations, detached.
## Unlike `_fleeing`, this cannot be reconstructed from the
## scheduler's own queued/active jobs after a load -- a cancelled blocked
## flee job that produced an exclusion is already gone from the queue by the
## time it is excluded, and an exhausted episode has no job at all -- so it
## is state_codec.gd's/state_hash()'s own responsibility to carry across a
## save/load (as `combatBlockedTargets`; an episode with no exclusions yet is
## an entry with an empty tile list), or a reload would re-try a tile the
## uninterrupted run had already proven unusable, or forget it ever owed
## the actor a recovery.
func get_blocked_targets() -> Dictionary:
	var copy: Dictionary = {}
	for actor_id in _episodes:
		copy[actor_id] = (_episodes[actor_id] as Dictionary).duplicate()
	return copy

## state_codec.gd's decode() counterpart to get_blocked_targets(): replaces
## this giver's own episode/exclusion state wholesale, then reconciles
## `_fleeing` against the scheduler's restored queue --
## every non-terminal `flee` job is re-adopted for the actor it is restricted
## to, and that actor's episode is (re)opened if the save predates episode
## persistence -- so the very first advance() after a load handles recovery,
## blocked-leg cancellation and destination picking exactly as the
## uninterrupted run would, and get_committed_jobs() is complete before the
## scheduler's first tick. Must therefore be called after the scheduler
## queue/scheduling state has been restored, never right after construction.
func restore_blocked_targets(data: Dictionary) -> void:
	_episodes = data
	_fleeing.clear()
	for job in (_list_jobs.call() as Array):
		if String(job.get("kind", "")) != FLEE_KIND or String(job.get("status", "")) not in ["queued", "active"]:
			continue
		var actor_id := String(_restrict_to_for.call(String(job["id"])))
		if actor_id.is_empty():
			continue
		_fleeing[actor_id] = String(job["id"])
		if not _episodes.has(actor_id):
			_episodes[actor_id] = {}

## Runs once per tick, alongside HaulGiver/NeedGiver: for every combat actor
## strictly below its own flee_hp_fraction that is not already pursuing a
## tracked flee job, interrupts whatever it is doing (an
## incident/haul/travel assignment must not simply run to completion while
## its worker is meant to be fleeing) and submits one, restricted to the
## fleeing actor, targeting a deterministic reachable tile away from its
## nearest hostile actor. An actor back at or above its own threshold whose
## flee job has ended resumes whatever this giver interrupted for it.
## content/jobs.json's "flee" kind completes itself one tick after arrival (a
## token `work_ticks: 1`, the same walk-then-finish shape "incident" already
## uses), so an actor still below threshold once it arrives gets a fresh leg
## the very next tick this giver runs -- a "keep moving away" reaction built
## from repeated single steps, never a bespoke continuous-chase loop of its
## own.
func advance(actors: Array[Dictionary], tick: int) -> void:
	for actor in actors:
		if not (actor.get("combat") is Dictionary):
			continue
		var actor_id: String = String(actor["id"])
		var health: Dictionary = actor.get("health", {})
		if bool(health.get("dead", false)):
			forget(actor_id)
			continue
		# Reconcile before any decision: a non-terminal flee
		# job this giver does not currently track (a load whose codec
		# predates restore_blocked_targets()'s own reconciliation, or a job
		# restored for an episode this giver still owns) is adopted here,
		# never duplicated, so both the recovery branch and the still-fleeing
		# status handling below see exactly what an uninterrupted run would.
		if _episodes.has(actor_id) and not _fleeing.has(actor_id):
			_adopt_existing_flee_job(actor_id)
		var should_flee := _hp_fraction(actor) < _flee_hp_fraction(actor, _content)
		if not should_flee:
			# Recovery is owned by the episode, never by a current flee job:
			# an exhausted episode (every destination
			# excluded, nothing submitted) or a freshly loaded one still owes
			# the actor this cleanup. Retires any outstanding flee job through
			# the shared finish boundary before resuming interrupted work.
			# cancel() is a no-op reject for a job already
			# terminal (job_queue.gd's _finish() status guard), so this is
			# safe whether the job is still queued, active, or has already
			# completed on its own -- without it, recovery during an active
			# leg left the flee job active (and its destination reservation
			# held) while _resume.call() below overwrote the worker's
			# assignment, orphaning the flee job and its reservation.
			if _fleeing.has(actor_id) or _episodes.has(actor_id):
				if _fleeing.has(actor_id):
					_cancel_job.call(String(_fleeing[actor_id]))
					_fleeing.erase(actor_id)
				_episodes.erase(actor_id)
				_resume.call(actor_id)
			continue
		if not _fleeing.has(actor_id):
			# A non-terminal flee job already exists (a fresh load) -- track
			# it, never duplicate it. Falls through into the
			# same status handling below instead of `continue`-ing past it, so
			# an adopted job already "queued" and blocked is excluded/
			# cancelled this same tick rather than one tick later than an
			# uninterrupted run would have.
			_adopt_existing_flee_job(actor_id)
		if _fleeing.has(actor_id):
			var job: Dictionary = _get_job.call(_fleeing[actor_id])
			var status := String(job.get("status", ""))
			if status == "active":
				continue
			if status == "queued":
				# Blocked (its own preferred destination reserved by another job
				# the instant this actor tried to commit to it, or genuinely
				# unreachable through a faction-forbidden door despite passing
				# the coarser region-connectivity check) never resolves itself:
				# JobQueue.tick() only ever retries the same target, forever.
				# Cancel it through the shared finish boundary
				# and fall through to pick a fresh, different destination this
				# same tick rather than leaving the actor stranded, still
				# "tracked" as fleeing but making no progress.
				if String(job.get("reason", "")) not in [BLOCKED_TARGET_RESERVED, BLOCKED_TARGET_UNREACHABLE]:
					continue
				var blocked: Dictionary = _episodes.get(actor_id, {})
				blocked[job["target"]] = true
				_episodes[actor_id] = blocked
				_cancel_job.call(String(_fleeing[actor_id]))
			_fleeing.erase(actor_id)
		var threat := TargetingType.nearest_hostile_actor(actor, actors, _relations)
		if threat.is_empty():
			continue
		var target = _pick_flee_target(actor, actors, threat, _episodes.get(actor_id, {}))
		if target == null:
			# Destination exhaustion: the episode (and its owed recovery)
			# stays open -- nothing is erased here.
			continue
		# The episode opens at the interrupt boundary itself, so ownership of
		# the paused work never depends on the leg being accepted or surviving.
		if not _episodes.has(actor_id):
			_episodes[actor_id] = {}
		_interrupt.call(actor)
		var result: Dictionary = _submit_job.call(target, FLEE_PRIORITY, tick, FLEE_KIND, actor_id)
		if result.get("ok", false):
			_fleeing[actor_id] = String(result["job_id"])

## True (and adopted into `_fleeing`) when a non-terminal `flee` job already
## exists restricted to actor_id -- the case right after a save/load, where
## this giver's own in-memory `_fleeing` map starts empty even though the
## scheduler's own (persisted) queue still carries the job this giver
## submitted before the save. Without this, a reload mid-flee would submit a
## second, duplicate leg every tick until the first one's own status changes.
func _adopt_existing_flee_job(actor_id: String) -> bool:
	for job in (_list_jobs.call() as Array):
		if String(job.get("kind", "")) != FLEE_KIND:
			continue
		if String(job.get("status", "")) not in ["queued", "active"]:
			continue
		if _restrict_to_for.call(String(job["id"])) != actor_id:
			continue
		_fleeing[actor_id] = String(job["id"])
		return true
	return false

## A deterministic, reachable, reservation-eligible tile to flee toward,
## ranking the 8 directions by how directly they point away from `threat`
## (ties broken by a fixed index, never insertion order) and, within each
## direction, the farthest in-bounds distance first, backing off toward
## shorter legs in that same direction before ever trying a worse direction
## (with distance as the outer loop, a long move in a bad direction could
## win over a short, available move in a good one).
## Every candidate must also strictly increase this actor's own distance from
## `threat` compared to its current tile -- a plain geometric ray can point
## "away" from the threat's last known tile yet still land closer to it once
## clamped to the map bounds (e.g. when the one open direction at the
## farthest distance is the direction toward the threat).
## Skips a candidate that is impassable, unreachable (a disconnected pocket),
## ineligible for actor_id to reserve (colony property for a hostile actor, a
## reserved cell), currently occupied by a hostile actor, already the target
## of another job's own live reservation (eligibility alone does not prove
## the tile is actually free right now), or named in `excluded` (a
## destination a just-cancelled blocked flee job for this same actor already
## proved unusable this tick). null when
## nothing at all qualifies.
func _pick_flee_target(actor: Dictionary, actors: Array[Dictionary], threat: Dictionary, excluded: Dictionary = {}):
	var ax := int(actor["x"])
	var ay := int(actor["y"])
	var actor_id: String = String(actor["id"])
	var start := Vector2i(ax, ay)
	var threat_pos := Vector2i(int(threat["x"]), int(threat["y"]))
	var away := Vector2i(signi(ax - threat_pos.x), signi(ay - threat_pos.y))
	if away == Vector2i.ZERO:
		away = Vector2i(1, 1)
	var hostile_tiles := _hostile_occupied_tiles(actor, actors)
	var start_distance := _distance_sq(start, threat_pos)
	for direction in _ranked_directions(away):
		for distance in range(FLEE_DISTANCE, 0, -1):
			var candidate := Vector2i(clampi(ax + direction.x * distance, 0, _bounds_max.x), clampi(ay + direction.y * distance, 0, _bounds_max.y))
			if candidate == start or hostile_tiles.has(candidate) or excluded.has(candidate):
				continue
			if _distance_sq(candidate, threat_pos) <= start_distance:
				continue
			if not bool((_passable_for_actor.call(actor_id, candidate.x, candidate.y) as Dictionary)["passable"]):
				continue
			if not bool(_may_reserve_target.call(actor_id, candidate)):
				continue
			if bool(_is_target_reserved.call(candidate.x, candidate.y)):
				continue
			if not bool(_reachable.call(start, candidate)):
				continue
			return candidate
	return null

## Squared Euclidean distance -- integer, deterministic, and sufficient since
## only relative comparisons against `start_distance` matter above.
static func _distance_sq(a: Vector2i, b: Vector2i) -> int:
	var delta := a - b
	return delta.x * delta.x + delta.y * delta.y

## Every tile currently occupied by a living actor hostile to `actor`'s own
## faction -- fleeing onto (or through, as a destination) a hostile actor's
## own tile would defeat the point.
func _hostile_occupied_tiles(actor: Dictionary, actors: Array[Dictionary]) -> Dictionary:
	var own_faction := TargetingType.actor_faction(actor)
	var occupied: Dictionary = {}
	for other in actors:
		if other == actor:
			continue
		if bool((other.get("health", {}) as Dictionary).get("dead", false)):
			continue
		if _relations.relation(own_faction, TargetingType.actor_faction(other)) != "hostile":
			continue
		occupied[Vector2i(int(other["x"]), int(other["y"]))] = true
	return occupied

## CANDIDATE_DIRECTIONS sorted by descending dot product with `away` (most
## directly away from the threat first), ties broken by each direction's own
## fixed index in CANDIDATE_DIRECTIONS -- deterministic and free of floating
## point, unlike a distance-based sort.
static func _ranked_directions(away: Vector2i) -> Array[Vector2i]:
	var scored: Array = []
	for i in CANDIDATE_DIRECTIONS.size():
		var direction: Vector2i = CANDIDATE_DIRECTIONS[i]
		scored.append({"direction": direction, "dot": direction.x * away.x + direction.y * away.y, "index": i})
	scored.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if int(a["dot"]) != int(b["dot"]):
			return int(a["dot"]) > int(b["dot"])
		return int(a["index"]) < int(b["index"]))
	var ranked: Array[Vector2i] = []
	for entry in scored:
		ranked.append(entry["direction"])
	return ranked
