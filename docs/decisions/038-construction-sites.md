# ADR 038: Persistent construction sites replace the single-worker `build` job

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
  (`docs/architecture/contracts/game-state.schema.json`, `state_codec.gd`, `save_io.gd`),
  `docs/architecture/core-budgets.json`'s cap for `toil_executor.gd`.
- **Implements:** issue #406 (objective #401, issue #405's follow-on).
- **Supersedes:** [ADR 027](027-build-job-core-budget-increase.md) and
  [ADR 036](036-build-multi-source-fetch-efficiency.md), whose single-worker `build` job kind,
  its two-reservation activation shape, and its per-job multi-source fetch plan are all removed
  by this task. [ADR 037](037-object-footprint-rotation.md)'s footprint/rotation/`build_cost`
  schema and `_set_object()`/`_object_footprint_tiles()` machinery are reused unchanged.

## Context

The `build` job (ADR 027, extended by ADR 035/036) modeled construction as a single job: one
colonist reserves a stockpiled item and a site together, hauls the item to the site, then
performs one timed `work` phase before the declared object appears. This required all the
declared `build_cost` to already be in stock at order time (rejected `blocked_missing_input`
otherwise), supported exactly one worker, and tied delivery and construction into one
job/reservation lifecycle. Issue #401 asks for a persistent site instead: an order is accepted
immediately regardless of stock, and materials arrive incrementally over time from one or more
delivery trips before a (potentially multi-builder) work phase begins.

## Decision

**A construction site is state, not a job.** `ConstructionSiteTable` (plain GDScript, no
scene/RNG/wall-clock dependency) holds one record per active site: `id`, `kind`, `origin`,
`orientation`, `required_materials` (copied from the kind's own `build_cost` at creation, so a
later content edit never retroactively changes an in-progress site), `held_materials`,
`progress`, `build_ticks`, `max_builders`, and `builder_ids`. `WorldState.get_construction_sites()`/
`get_construction_site(x, y)` mirror `get_objects()`/`get_object()` exactly, including
footprint-aware per-tile lookup.

**The `build` command creates the site and reserves its footprint immediately, with no stock
check.** `_apply_construction_submission()` validates the footprint (in-bounds, empty, passable,
not already claimed, no enclosure) exactly like the superseded command did, but drops the
`blocked_missing_input` check entirely: a site is a standing commitment that waits for materials,
not a one-shot order requiring them up front. On acceptance, every footprint tile is reserved
directly on the shared `ReservationTable`, owner `"site:<id>"` — never a job id, since no job
exists yet. `ReservationInvariants.find_orphaned_reservations()` gained an optional
`extra_active_owners: Array[String]` parameter specifically so this non-job owner is never
flagged orphaned; every existing caller passes nothing, leaving the check byte-identical to
before this task.

**A new job-giver, not a bigger job, drives delivery and construction.** `ConstructionGiver`
(mirroring `HaulGiver`'s own "decide WHEN, submit through the shared queue" shape) runs once per
tick: for each site still short of materials with no fetch job already in flight for it, it
submits one `site_fetch` job sized to what the site still needs of one missing kind (up to hands
capacity); once every required material is fully held, it tops the site's active/queued
`site_work` job count up to `max_builders`.

**`site_fetch` always carries exactly one kind, but reuses ADR 036's own on-demand nearest-source
search for that kind (round 3 review: #400's hands-filling rules apply in full, not merely its
hands-capacity clamp).** Its toils are `[reserve, go_to, pick_up, go_to, deposit, release_all]` —
haul's own shape with a new `deposit` toil in place of `place`. `ConstructionGiver` still submits
a fresh job whenever the previous one terminates and material is still short, and still never asks
one job to hop between *kinds* (unlike ADR 036's own multi-kind build job) — but within that one
kind, the job now behaves exactly like ADR 036's single-source build job once did: `ConstructionGiver`'s
own submission-time source choice is a position-agnostic seed (no colonist is chosen yet at
submission), which `WorldState._resolve_freshly_activated_site_fetch_sources()` corrects to the true
nearest-reachable source of that kind the instant the job actually activates with a colonist known,
using the same deterministic route-cost search (`_route_cost()`, not open-field Chebyshev) ADR 036's
`_next_build_source()` used. After each `pick_up`, `WorldState._toil_on_pick_up_success()` re-runs
that same search: if hands already cover the site's own remaining need of that kind, hands are full,
or no further unclaimed source of the kind exists, the job delivers with whatever it holds
(`JobQueue.mark_site_fetch_delivering()`); otherwise it compares the site's own route cost against
the next candidate's and only delivers a partial load when the site is no farther — the "very close"
rule ADR 036 established — reserving and retargeting onto the next source
(`JobQueue.retarget_site_fetch_source()`) otherwise. `_toil_pick_up_count_for()`'s hands-filling
`count` (clamped to what the site still needs of that kind) now also subtracts whatever of that kind
the colonist already holds from an earlier hop, so a second hop can never request more than the site
actually still needs. Non-goals still explicitly defers the harder N-builder efficiency question to
a follow-up task; only the single-kind nearest-source/partial-load mechanism is in scope here.

**`deposit` is a new toil verb, not an extension of `place`.** It transfers every hands entry into
a construction site's own `held_materials` (`ConstructionSiteTable.deposit()`, clamped to what the
site still needs, never past `required_materials`) instead of minting a ground item. Sharing
`place` would have meant branching that toil's own body on "is this destination a site or a
cell," which `docs/architecture/extension-points.md`'s "Toil" section treats as exactly what a new
verb exists to avoid. No other toil-vocabulary change was needed: the `go_to` arrival-hook
machinery ADR 027 built for `build`'s `[go_to, pick_up, go_to, work]` shape already dispatches
`deposit` correctly with zero changes, since `site_fetch`'s shape is structurally identical to
`haul`'s (no `work` toil at all) and `_next_toil_index()`'s `place`/`deposit` cases already share
one code path (the match statement's default `_: return i` arm).

**`site_work` reuses the single-leg `work` toil unmodified, but its duration is read from the
site, not `content/jobs.json`.** Its toils are `[reserve, go_to, work, release_all]` — the same
shape as `dig`/`chop`/`mine`, needing zero `toil_executor.gd` changes beyond the vocabulary
addition above. Because a site's own `build_ticks` varies per object kind (a workbench's 120
against a wall's 40) and its *remaining* duration varies with how much progress other builders
have already contributed, `content/jobs.json`'s single per-kind `work_ticks` constant cannot
express it. `WorldState._resume_work_progress()` — the same job-id-scoped "resume stored progress"
hook ADR 027's interrupt/resume design already threads through `start_work()` — gains a
`site_work` branch that always returns `build_ticks - progress`, computed fresh from the site
record on every call, whether this is a genuinely fresh activation or a resumption after a
critical-need interrupt; `_set_work_progress()` gains a matching branch that adds one tick to the
site's own `progress` (`ConstructionSiteTable.add_progress()`, summed across every active
builder's own job, not a private per-job counter) on every non-final tick, with the final tick's
contribution added directly in `_toil_on_work_complete()`'s own `"site_work"` case before checking
completion. Neither branch touches the generic tile-keyed `_work_progress`/`_work_progress_owner`/
`_suspended_work_progress` caches at all for this kind: the site's own `progress` field is the one
persisted, authoritative counter, so there is nothing to cache or reconcile. This design sums N
concurrent builders' contributions into one shared counter; issue #401 closed the gap noted here at
the time of this ADR (each builder's own `work` toil completing on ITS OWN locally-seeded countdown,
so two builders starting together finished no faster than one) by also checking the threshold on
every non-final tick's own contribution, not only a job's own countdown reaching zero — see
docs/architecture/orders-and-movement.md's "Completion" section.

**A builder never works standing on the site itself.** `go_to_force_trim_last` (ADR 027's own hook)
returns true for `site_work`'s only leg and for `site_fetch`'s second (delivery) leg, landing a
builder adjacent to the site rather than on its own origin tile — critical, not merely tidy: a
`site_fetch` delivery that parked a colonist exactly on the origin would let
`GlobalAssignmentScheduler`'s own "already at target" shortcut skip `advance_go_to()`'s trim
entirely for the very next `site_work` leg, walling the colonist into the structure the instant it
completes (caught by `test_bedroom.gd`'s own multi-wall room fixture during this task's own
implementation). Because `site_work` has no `pick_up` in its toils, `_is_first_leg()` always reports
it as a first leg, which would otherwise let it use the scheduler's own precomputed path via
`start_assignment()` — a path `GlobalAssignmentScheduler` itself never trims for a currently-passable
target, unlike chop/forage's already-impassable one. `_toil_go_to_skip_assignment_path()` (a hook
`toil_executor.gd`'s `_start_current_toil()` already supported, reused rather than re-invented) forces
every `site_work` go_to through the same fresh bounded search `advance_go_to()`'s trim actually runs
in, so the invariant holds regardless of how the scheduler itself would have routed it.

**Completion places the object and tears down the site.** Once a `site_work` job's own local
countdown reaches zero (which, for the one-builder case this task exercises, is exactly when
`progress` reaches `build_ticks`), `_finalize_construction_site()` places the declared object via
`_set_object()` (t1's footprint/orientation-aware placement, unchanged), releases the site's own
footprint reservation, completes any other still-active builder job on the site (best-effort, for
a future multi-builder task), and removes the site record — discarding `held_materials`, already
fully spent by definition since `ConstructionGiver` never submits `site_work` before
`materials_met()`.

**`cancel_site {x, y}` terminates the whole site.** Every in-flight `site_fetch`/`site_work` job on
the site is finished through the existing `_finish_job()` terminal path (a mid-fetch builder's own
carried hands drop via the existing `_drop_carried_haul_item()`, #400's rule, unchanged); every
held material is placed on the nearest free tile adjacent to the site's footprint (one distinct
tile per kind where possible, the same north/west/east/south adjacency order
`_dig_item_placement()` already uses for a single tile); the site's own footprint reservation is
released; and the record is removed. There is no separate "ghost" to erase — a future presentation
layer (t4) draws it from `get_construction_sites()`, which this call already empties.

**`wall`/`door`/`bed` migrate onto this exact flow with no code change of their own**, since ADR
037 already gave every object kind `build_ticks`/`max_builders`/a list-shaped `build_cost` —
exactly the data this design reads. Their `build_ticks: 40`/`max_builders: 1` reproduce the
superseded job's own single-worker, 40-tick shape byte-for-byte.

## Alternatives considered

- **Keep `build` as the job kind, extending its toils in place.** Rejected: the superseded job
  conflated "acquire the site" with "is currently being worked", which cannot express a site that
  exists before any worker is assigned, accepts partial deliveries from more than one job over
  time, or supports more than one concurrent builder. A new job-giver plus a persistent site
  record is the direct application of `docs/architecture/extension-points.md`'s own "Job-giver"
  extension point to "a decision about *when* a job should exist", which this clearly is.
- **A persisted `fetch_plan` reproducing ADR 036's per-job multi-KIND hopping for `site_fetch`.**
  Rejected as unnecessary complexity: that mechanism existed to make one job efficient across
  several DIFFERENT-kind sources it might visit in sequence within a single multi-entry
  `build_cost`; a job-giver that resubmits a fresh single-kind job whenever material of that kind
  is still short needs no such cross-kind plan. (Round 3 review: this is narrower than the
  originally-rejected alternative's scope — the nearest-source/partial-load SEARCH itself, for a
  single kind, is not skipped; see the Decision section above.)
- **Force-complete every active builder's job the instant summed progress crosses `build_ticks`**
  (a `_set_work_progress()`-driven early completion, rather than waiting for each job's own local
  countdown). Rejected: it would need a job to complete itself from inside another toil's own
  per-tick advance call, a bespoke completion path outside the toil vocabulary's existing
  "activation/reactivation boundary" discipline (AGENTS.md), for a proportional-speedup property
  this task's Non-goals does not require and no acceptance check exercises.

## Consequences

- `content/jobs.json`: `build` is removed; `site_fetch`/`site_work` added, both `labour: "build"`
  (unchanged labour-table key, so existing colonist labour toggles need no migration).
- `content/objects.json`: `workbench` added (`footprint [2, 1]`, `rotatable: true`,
  `build_cost: [{wood, 3}, {stone, 4}]`, `build_ticks: 120`, `max_builders: 2`).
- `game/scripts/core/jobs/job_queue.gd`: `BUILD_KIND`/`attach_build()`/`_tick_build()`/
  `_reactivate_build()` are removed; `SITE_FETCH_KIND`/`SITE_WORK_KIND`/`attach_site()`/
  `_tick_site_fetch()`/`_tick_site_work()`/`_reactivate_site_fetch()` replace them. A `site_fetch`
  job reserves only its source item (the site's footprint is never a job-owned reservation); a
  `site_work` job reserves nothing at all. `retarget_build_source()`/`mark_build_delivering()` are
  likewise removed, but reappear renamed as `retarget_site_fetch_source()`/
  `mark_site_fetch_delivering()` (round 3: #400's hands-filling rules, see the Round 3 addendum
  below) — the same shape, gated on `SITE_FETCH_KIND` instead of the removed `BUILD_KIND`.
- `game/scripts/core/world_state.gd`: 4494 -> 4451 lines net, despite adding the new command
  handlers, `ConstructionSiteTable` wiring, and toil hooks — ADR 036's entire per-job
  multi-source-fetch machinery (`_next_build_source()`/`_build_route_cost()`/
  `_resolve_freshly_activated_build_sources()`/`_active_build_job_ids()`) and ADR 027's own
  `_find_available_build_item()`/`_pending_build_jobs()`/`_build_completion_failure()`/
  `_consume_build_cost()` are all removed; a new `_toil_go_to_skip_assignment_path()` (forcing a
  `site_work` job's own go_to through the fresh bounded search that actually honours
  `go_to_force_trim_last`, since its single leg would otherwise always qualify for
  `GlobalAssignmentScheduler`'s own precomputed-path shortcut, which knows nothing about the
  trim) replaces the old one of the same name, net removing more than it added. Cap raised
  4550 -> 4470 for headroom, not because this file grew past its old cap.
- `game/scripts/core/jobs/toil_executor.gd`: 907 -> 957 lines (+50): the `deposit` toil, its
  `VOCABULARY`/match-statement wiring, and the two new injected callables
  (`site_exists`/`site_deposit`). Cap raised 920 -> 970.
- `docs/architecture/contracts/game-state.schema.json`: a job's `buildKind` field is removed
  (the object kind to place lives on the construction site record, not duplicated per job); `site`
  is now required when `kind` is `site_fetch` or `site_work` (generalizing the old `build`-only
  rule); a new optional top-level `constructionSites` array. No `schemaVersion` bump: every change
  is additive/optional, and a save with no sites (or none at all, predating this task) loads
  unchanged.
- Round 2 addendum: `game/scripts/boot.gd`'s Cancel tool (`_order_tile()`/`_cancel_job_for_tile()`)
  now keys off any job's own `site` field (generalizing the superseded `build` job's `kind ==
  "build"` special case to `site_fetch`/`site_work`), and falls back to `get_construction_site()`
  when no job exists for the tile yet — a freshly-ordered site has none until ConstructionGiver's
  next tick. `world_state.gd` gained `_apply_cancel_job_command()`: a `cancel_job {job_id}` whose
  id names a live construction site tears the site down through the same `_cancel_construction_site()`
  `cancel_site {x, y}` uses, rather than a second cancellation path; `_apply_construction_submission()`
  mirrors its own new site id onto `job_id` (alongside `site_id`) so the two stay comparable. This
  keeps `cancel_job` as boot.gd's one Cancel-tool verb until t4 rewires the toolbar onto `cancel_site`
  directly; `cancel_site {x, y}` remains the primary, spec'd command for every other caller.
  `game/scripts/core/world_state.gd`: 4451 -> 4481 lines (+30). Cap raised 4470 -> 4490.
- Round 3 addendum (review finding: the original submission-time `_choose_source()` seed was never
  corrected to the true nearest source, and a source shorter than the remaining need always
  delivered immediately instead of weighing a nearer top-up): `world_state.gd` gains
  `_route_cost()`/`_UNREACHABLE_ROUTE_COST` (ADR 036's own `_build_route_cost()`/its constant,
  reintroduced under a kind-agnostic name), `_pending_site_fetch_jobs()`/`_next_site_fetch_source()`
  (ADR 036's own `_pending_build_jobs()`/`_next_build_source()`, adapted to a single declared kind
  instead of a `build_cost` list), `_active_site_fetch_job_ids()`/
  `_resolve_freshly_activated_site_fetch_sources()` (ADR 036's own `_active_build_job_ids()`/
  `_resolve_freshly_activated_build_sources()`), the `is_first_leg`/`on_pick_up_success` toil hooks
  (`_toil_is_first_leg()`/`_toil_on_pick_up_success()`, mirroring ADR 036's own build-only versions
  of the same hooks, which `toil_executor.gd` already supported generically and left unset for
  `site_fetch` before this round), and a `_site_fetch_source_retargeted` tracking dict (renamed from
  the removed `_build_source_retargeted`) feeding an extended `_toil_go_to_skip_assignment_path()`.
  `job_queue.gd` gains `retarget_site_fetch_source()`/`mark_site_fetch_delivering()` (see above).
  Three stale `["haul", "build"]` job-kind checks left over from the `build`-to-`site_fetch`
  migration (`_resolve_refused_reservations()`, `_trap_actor()`, `_resume_interrupted_job()` — none
  of which could ever match `"build"` again, since no job kind is named that anymore, silently
  skipping the mid-carry cargo drop those paths exist for) are corrected to `["haul", "site_fetch"]`.
  `_toil_pick_up_count_for()` now also subtracts the colonist's own already-held count of the kind
  so a second hop's request reflects what is actually still needed. `game/scripts/core/world_state.gd`:
  4481 -> 4723 lines (+242). Cap raised 4490 -> 4760. `game/scripts/core/jobs/job_queue.gd`:
  719 -> 755 lines (+36). Cap raised 730 -> 790.

## Known limitations

- ~~N-builder speedup is not fully realized~~ — closed by issue #401: completion is now checked on
  every builder's own non-final-tick contribution, not only when a job's own locally-seeded
  countdown reaches zero, so two concurrent builders finish in roughly half the ticks a lone one
  would.
- Completion does not re-validate that no actor is standing on the site's footprint (the
  superseded `build` job's own `_build_completion_failure()` guard). Site tiles stay passable
  through construction, so a colonist could in principle be standing on one at the exact tick
  progress reaches `build_ticks`; `_set_object()` would place the object under it. Not exercised
  by this task's acceptance tests; a follow-up should port that guard if this proves reachable in
  practice.
- `game/scripts/boot.gd`'s Cancel tool still speaks `cancel_job`/a job's own `id` rather than the
  dedicated `cancel_site {x, y}` command (round 2: `boot.gd` was authorized into this task's
  `Owned paths` specifically to keep `test_order_input.gd` passing, not to do t4's toolbar
  rewrite). `cancel_site {x, y}` stays the correct, spec'd command for any other caller; rewiring
  the toolbar to prefer it directly over the `cancel_job` alias is still t4's own follow-up.
