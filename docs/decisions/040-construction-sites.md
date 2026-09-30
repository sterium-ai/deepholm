# ADR 040: Persistent construction sites replace the single-worker `build` job

> **In short:** Ordering a building now places a construction site right away, even if materials are missing. Colonists bring materials to the site over several trips, and more than one builder can work on it until the finished object appears.

- **Status:** accepted
- **Date:** 2026-09-25
- **Scope:** a new `deposit` toil (`game/scripts/core/jobs/toil_executor.gd`), two new job kinds
  `site_fetch`/`site_work` replacing `build` (`game/content/jobs.json`,
  `game/scripts/core/jobs/job_queue.gd`), a new `ConstructionSiteTable` module
  (`game/scripts/core/objects/construction_site.gd`), a new job-giver
  (`game/scripts/core/jobs/givers/construction_giver.gd`), a `workbench` content row
  (`game/content/objects.json`), a `cancel_site` command, an optional
  `extra_active_owners` parameter on `ReservationInvariants.find_orphaned_reservations()`
  (`game/scripts/core/jobs/reservation_invariants.gd`), persistence for site records
  (`docs/architecture/contracts/game-state.schema.json`, `state_codec.gd`, `save_io.gd`), the
  viewer's Cancel tool (`game/scripts/boot.gd`), and `docs/architecture/core-budgets.json`'s caps
  for `world_state.gd`, `toil_executor.gd`, and `job_queue.gd`.
- **Supersedes:** [ADR 028](028-build-job-core-budget-increase.md) and
  [ADR 038](038-build-multi-source-fetch-efficiency.md): their single-worker `build` job kind, its
  two-reservation activation shape, and its per-job multi-kind fetch plan are removed.
  [ADR 039](039-object-footprint-rotation.md)'s footprint, rotation, and `build_cost` schema and
  its `_set_object()`/`_object_footprint_tiles()` machinery are reused unchanged.

## Context

The `build` job (ADR 028, extended by ADR 037 and ADR 038) modelled construction as a single job:
one colonist reserved a stockpiled item and a site together, hauled the item to the site, then
performed one timed `work` phase before the object appeared. This required the whole
`build_cost` to be in stock at order time (otherwise the order was rejected with
`blocked_missing_input`), supported exactly one worker, and tied delivery and construction into
one job and reservation lifecycle. A persistent site replaces it: an order is accepted
immediately regardless of stock, and materials arrive over one or more delivery trips before a
work phase, possibly with several builders, begins.

## Decision

**A construction site is state, not a job.** `ConstructionSiteTable` (plain GDScript, with no
scene, RNG, or wall-clock dependency) holds one record per active site: `id`, `kind`, `origin`,
`orientation`, `required_materials` (copied from the kind's `build_cost` at creation, so a later
content edit never changes an in-progress site), `held_materials`, `progress`, `build_ticks`,
`max_builders`, and `builder_ids`. `WorldState.get_construction_sites()`/
`get_construction_site(x, y)` mirror `get_objects()`/`get_object()`, including footprint-aware
per-tile lookup.

**The `build` command creates the site and reserves its footprint immediately, with no stock
check.** `_apply_construction_submission()` validates the footprint (in bounds, empty, passable,
not already claimed, no enclosure) as the superseded command did, but drops the
`blocked_missing_input` check: a site is a standing commitment that waits for materials, not a
one-shot order requiring them up front. On acceptance, every footprint tile is reserved directly
on the shared `ReservationTable` with owner `"site:<id>"`, never a job id, since no job exists yet.
`ReservationInvariants.find_orphaned_reservations()` gains an optional
`extra_active_owners: Array[String]` parameter so this non-job owner is never flagged as orphaned;
existing callers pass nothing, so their check is unchanged.

**A new job-giver, not a bigger job, drives delivery and construction.** `ConstructionGiver`
(following `HaulGiver`'s "decide when, submit through the shared queue" shape) runs once per tick.
For each site still short of materials with no fetch job already in flight for it, it submits one
`site_fetch` job sized to what the site still needs of one missing kind (up to hands capacity).
Once every required material is held, it tops up the site's active and queued `site_work` jobs to
`max_builders`.

**`site_fetch` always carries exactly one kind, but applies ADR 038's nearest-source search and
hands-filling rules to that kind.** Its toils are `[reserve, go_to, pick_up, go_to, deposit,
release_all]`: haul's shape, with a new `deposit` toil in place of `place`. `ConstructionGiver`
submits a fresh job whenever the previous one terminates and material is still short, and never
asks one job to switch between *kinds* (unlike ADR 038's multi-kind build job). Within one kind,
the job behaves as ADR 038's build job did:

- `ConstructionGiver`'s submission-time source is a position-agnostic seed (no colonist is chosen
  yet). `WorldState._resolve_freshly_activated_site_fetch_sources()` replaces it with the true
  nearest reachable source of that kind the moment the job activates with a known colonist, using
  the deterministic route-cost search (`_route_cost()`, not open-field Chebyshev distance) that
  ADR 038's `_next_build_source()` used.
- After each `pick_up`, `WorldState._toil_on_pick_up_success()` re-runs that search. If hands
  already cover the site's remaining need of the kind, hands are full, or no further unclaimed
  source of the kind exists, the job delivers what it holds (`JobQueue.mark_site_fetch_delivering()`).
  Otherwise it compares the site's route cost with the next candidate's and delivers a partial
  load only when the site is no farther (ADR 038's "very close" rule); if not, it reserves and
  retargets onto the next source (`JobQueue.retarget_site_fetch_source()`).
- `_toil_pick_up_count_for()` clamps each `pick_up` to what the site still needs of the kind,
  minus whatever of that kind the colonist already holds from an earlier hop, so a second hop never
  requests more than the site needs.

**`deposit` is a new toil verb, not an extension of `place`.** It transfers every hands entry into
the site's `held_materials` (`ConstructionSiteTable.deposit()`, clamped so it never exceeds
`required_materials`) instead of minting a ground item. Sharing `place` would have meant branching
that toil's body on "is the destination a site or a cell", which the "Toil" section of
[extension-points.md](../architecture/extension-points.md) says a new verb exists to avoid. No
other toil-vocabulary change is needed: the `go_to` arrival-hook machinery ADR 028 built for
`build`'s `[go_to, pick_up, go_to, work]` shape dispatches `deposit` correctly without changes,
since `site_fetch`'s shape is structurally identical to `haul`'s (no `work` toil) and
`_next_toil_index()` handles `place` and `deposit` through the same default `_: return i` arm.

**`site_work` reuses the single-leg `work` toil unchanged, but reads its duration from the site,
not from `content/jobs.json`.** Its toils are `[reserve, go_to, work, release_all]`, the same shape
as `dig`/`chop`/`mine`. A site's `build_ticks` varies per object kind (120 for a workbench, 40 for
a wall), and its *remaining* duration depends on how much progress other builders have already
contributed, so `content/jobs.json`'s single per-kind `work_ticks` cannot express it.
`WorldState._resume_work_progress()`, the job-scoped "resume stored progress" hook ADR 028's
interrupt/resume design threads through `start_work()`, gains a `site_work` branch that returns
`build_ticks - progress`, computed from the site record on every call, for both fresh activations
and resumptions after a critical-need interrupt. `_set_work_progress()` gains a matching branch
that adds one tick to the site's `progress` (`ConstructionSiteTable.add_progress()`, summed across
all active builders' jobs rather than a private per-job counter) on every non-final tick; the final
tick's contribution is added in `_toil_on_work_complete()`'s `"site_work"` case before checking
completion. Neither branch touches the generic tile-keyed `_work_progress`/`_work_progress_owner`/
`_suspended_work_progress` caches for this kind: the site's `progress` field is the single
persisted, authoritative counter, so there is nothing to cache or reconcile. Completion is checked
against that shared counter on every builder's non-final-tick contribution, not only when one
job's own countdown reaches zero, so two concurrent builders finish in roughly half the ticks of
one (see the "Completion" section of
[orders-and-movement.md](../architecture/orders-and-movement.md)).

**A builder never works standing on the site itself.** `go_to_force_trim_last` (ADR 028's hook)
returns true for `site_work`'s only leg and for `site_fetch`'s second (delivery) leg, so a builder
stops adjacent to the site rather than on its origin tile. This is essential, not cosmetic: if a
`site_fetch` delivery parked a colonist on the origin, `GlobalAssignmentScheduler`'s "already at
target" shortcut would skip `advance_go_to()`'s trim for the following `site_work` leg, walling the
colonist into the structure when it completes (caught by `test_bedroom.gd`'s multi-wall room
fixture). Because `site_work` has no `pick_up` toil, `_is_first_leg()` always reports it as a first
leg, which would otherwise let it use the scheduler's precomputed path via `start_assignment()`;
`GlobalAssignmentScheduler` never trims that path for a currently passable target (unlike the
already-impassable targets of chop and forage). `_toil_go_to_skip_assignment_path()`, a hook
`toil_executor.gd`'s `_start_current_toil()` already supported, forces every `site_work` `go_to`
through the fresh bounded search in which `advance_go_to()`'s trim runs, so the invariant holds
regardless of how the scheduler would have routed it. A `site_fetch` job whose source was
retargeted is tracked in `_site_fetch_source_retargeted` and routed through the same hook.

**Completion places the object and tears down the site.** When progress reaches `build_ticks`,
`_finalize_construction_site()` places the declared object via `_set_object()` (ADR 039's
footprint- and orientation-aware placement), releases the site's footprint reservation, completes
any other still-active builder job on the site, and removes the site record. `held_materials` is
discarded; it is fully spent by definition, since `ConstructionGiver` never submits `site_work`
before `materials_met()`.

**`cancel_site {x, y}` terminates the whole site.** Every in-flight `site_fetch`/`site_work` job on
the site is finished through the existing `_finish_job()` terminal path (a mid-fetch builder's
carried hands drop via the existing `_drop_carried_haul_item()`, per the hands rules of ADR 037).
Every held material is placed on the nearest free tile adjacent to the site's footprint (one
distinct tile per kind where possible, using the north/west/east/south order `_dig_item_placement()`
uses for a single tile), the site's footprint reservation is released, and the record is removed.
There is no separate "ghost" to erase: the presentation layer draws sites from
`get_construction_sites()`, which this call empties.

**`cancel_job` on a site id cancels the site.** `world_state.gd`'s `_apply_cancel_job_command()`
treats a `cancel_job {job_id}` whose id names a live construction site as a site cancellation,
through the same `_cancel_construction_site()` that `cancel_site {x, y}` uses rather than a second
path; `_apply_construction_submission()` mirrors the new site id onto `job_id` (alongside
`site_id`) so the two stay comparable. In the viewer (`game/scripts/boot.gd`), the Cancel tool
issues `cancel_site` for a tile that has a construction site, and otherwise falls back to
`cancel_job` for the tile's job, which it finds by any job's `site` field (generalizing the old
`kind == "build"` special case to `site_fetch`/`site_work`).

**`wall`, `door`, and `bed` move onto this flow with no code of their own**, since ADR 039 already
gave every object kind `build_ticks`, `max_builders`, and a list-shaped `build_cost`, which is
exactly the data this design reads. Their `build_ticks: 40` and `max_builders: 1` reproduce the
superseded job's single-worker, 40-tick behaviour exactly.

## Alternatives considered

- **Keep `build` as the job kind and extend its toils in place.** Rejected: the superseded job
  conflated "acquire the site" with "is currently being worked", which cannot express a site that
  exists before any worker is assigned, accepts partial deliveries from several jobs over time, or
  supports more than one concurrent builder. A new job-giver plus a persistent site record is a
  direct use of the "Job-giver" extension point in
  [extension-points.md](../architecture/extension-points.md) for "a decision about *when* a job
  should exist", which this is.
- **A persisted `fetch_plan` reproducing ADR 038's per-job multi-*kind* hopping for
  `site_fetch`.** Rejected as unnecessary: that mechanism made one job efficient across several
  sources of *different* kinds within one multi-entry `build_cost`, and a job-giver that resubmits
  a fresh single-kind job whenever material is short needs no cross-kind plan. The
  nearest-source and partial-load search *within* a kind is still applied (see "Decision").
- **Force-complete every active builder's job the instant summed progress crosses `build_ticks`,
  driven from `_set_work_progress()`.** Rejected: a job would have to complete itself from inside
  another toil's per-tick advance, a bespoke completion path outside the toil vocabulary's
  "activation/reactivation boundary" discipline ([AGENTS.md](../../AGENTS.md)).

## Consequences

- `content/jobs.json`: `build` is removed, and `site_fetch`/`site_work` are added, both with
  `labour: "build"` (the labour-table key is unchanged, so existing colonist labour toggles need no
  migration).
- `content/objects.json`: `workbench` is added (`footprint [2, 1]`, `rotatable: true`,
  `build_cost: [{wood, 3}, {stone, 4}]`, `build_ticks: 120`, `max_builders: 2`).
- `game/scripts/core/jobs/job_queue.gd`: `BUILD_KIND`, `attach_build()`, `_tick_build()`, and
  `_reactivate_build()` are removed; `SITE_FETCH_KIND`, `SITE_WORK_KIND`, `attach_site()`,
  `_tick_site_fetch()`, `_tick_site_work()`, and `_reactivate_site_fetch()` replace them. A
  `site_fetch` job reserves only its source item (the site's footprint is never a job-owned
  reservation), and a `site_work` job reserves nothing. `retarget_build_source()`/
  `mark_build_delivering()` become `retarget_site_fetch_source()`/`mark_site_fetch_delivering()`,
  with the same shape but gated on `SITE_FETCH_KIND`. The file grows from 719 to 755 lines; its cap
  rises from 730 to 790.
- `game/scripts/core/world_state.gd`: ADR 038's per-kind multi-source machinery
  (`_next_build_source()`, `_build_route_cost()`, `_resolve_freshly_activated_build_sources()`,
  `_active_build_job_ids()`) and ADR 028's `_find_available_build_item()`,
  `_pending_build_jobs()`, `_build_completion_failure()`, and `_consume_build_cost()` are removed.
  Their single-kind equivalents are reintroduced under site names: `_route_cost()`/
  `_UNREACHABLE_ROUTE_COST`, `_pending_site_fetch_jobs()`/`_next_site_fetch_source()`,
  `_active_site_fetch_job_ids()`/`_resolve_freshly_activated_site_fetch_sources()`, and the
  `is_first_leg`/`on_pick_up_success` toil hooks (`_toil_is_first_leg()`/
  `_toil_on_pick_up_success()`). Three job-kind checks that still read `["haul", "build"]`
  (`_resolve_refused_reservations()`, `_trap_actor()`, `_resume_interrupted_job()`) now read
  `["haul", "site_fetch"]`; with no job kind named `build` any more, they would otherwise have
  silently skipped the mid-carry cargo drop those paths exist for. Together with the new command
  handlers and `ConstructionSiteTable` wiring, the file ends at 4723 lines, and its cap is 4760.
- `game/scripts/core/jobs/toil_executor.gd`: 907 -> 957 lines (+50) for the `deposit` toil, its
  `VOCABULARY` and match-statement wiring, and two new injected callables (`site_exists`,
  `site_deposit`). The cap rises from 920 to 970.
- `docs/architecture/contracts/game-state.schema.json`: a job's `buildKind` field is removed (the
  object kind lives on the site record, not duplicated per job); `site` is required when `kind` is
  `site_fetch` or `site_work` (generalizing the old `build`-only rule); and there is a new optional
  top-level `constructionSites` array. There is no `schemaVersion` bump: every change is additive
  or optional, and a save with no sites, including one written before this change, loads
  unchanged.

## Known limitations

- Completion does not re-check that no actor is standing on the site's footprint (the superseded
  `build` job's `_build_completion_failure()` guard). Site tiles stay passable during construction,
  so a colonist could in principle be standing on one at the exact tick progress reaches
  `build_ticks`, and `_set_object()` would place the object under it. This is not exercised by the
  current tests; the guard should be ported if it proves reachable in practice.
