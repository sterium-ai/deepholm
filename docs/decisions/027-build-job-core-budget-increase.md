# ADR 027: `build` job kind, the second allowed core addition, raises core budgets

- **Status:** accepted
- **Date:** 2026-09-23
- **Scope:** a new `build` job kind (`content/jobs.json`), a `build_cost` field on buildable
  `content/objects.json` entries (`content/schemas/objects.schema.json`), a `build {kind, x, y}`
  command in `game/scripts/core/world_state.gd`, a Build toolbar tool
  (`game/scripts/boot.gd`, `game/scripts/viewer/map_view.gd`), a correction to
  `game/scripts/core/jobs/toil_executor.gd`'s per-leg arrival dispatch, `build`'s own
  activation/reactivation reservation lifecycle in `game/scripts/core/jobs/job_queue.gd`,
  persistence for its own site/kind fields in
  `game/scripts/core/persistence/state_codec.gd` (with `game/scripts/core/persistence/save_io.gd`
  validating them), and `docs/architecture/core-budgets.json`'s caps for the three touched core
  files.
- **Implements:** issue #278/#303 (t7 of the objective started by #277's regions/rooms/incidents
  work), the objective's second and last allowed new core addition.
- **Supersedes:** this ADR's own round-1 revision, which shipped `build` ending in `place`
  (no timed work phase, reservations acquired at submission) after tracing a real
  `toil_executor.gd` limitation it treated as out of scope. That limitation is now fixed; this
  revision documents the completed design.

## Decision

`build` reuses the existing fixed toil vocabulary exactly as the objective's "Must not change"
section requires: `content/jobs.json`'s entry declares `["reserve", "go_to", "pick_up", "go_to",
"work", "release_all"]`, a strict subset of `{reserve, go_to, pick_up, place, work,
release_all}` — haul's own shape with `work` in place of `place`. No new verb was added to
`toil_executor.gd`; its existing dispatch was corrected instead (Non-goals explicitly permits
this: "its existing dispatch ... may be corrected so a haul-then-work shape composes correctly").

**Why the first attempt's `place`-ending sequence was wrong, and what fixing it required.**
Tracing `toil_executor.gd`'s generic `advance()` against `[go_to, pick_up, go_to, work]` showed
it could not work without a correction: `advance()` picks its whole per-tick dispatch branch on
whether the literal string `"work"` appears anywhere in a job kind's toils array, and once it
does, every `go_to` leg's arrival used the same hardcoded default (`on_arrive` unset ->
`start_work()`) — there was no way to tell leg one (which must lead into `pick_up`) from leg two
(which must lead into `work`) apart. That default was harmless for `dig`/`chop`/`mine`/`till`/
`sow`/`sleep` (each has exactly one `go_to`, always meant to lead into `work`) and for haul's own
two legs (haul has no `work_ticks` entry at all, so the same default call was always a no-op),
but for `build`'s new `[go_to, pick_up, go_to, work]` shape it would fire `start_work()` the
instant the colonist reached the **wood**, before `pick_up` ever ran.

The fix is `ToilExecutor._arrival_hook()`/`_next_toil_after_go_to()`: for the `go_to` occurrence
`is_first` selects, look at what toil actually follows it in the declared array (mirroring
`_next_toil_index()`'s own is_first/pick_up-occurrence reasoning) and pass an explicit no-op
`on_arrive` when it is `pick_up`, leaving that leg's arrival to the ordinary
`advance()`/`_next_toil_index()` dispatch on the following tick instead of auto-starting work.
`ToilExecutor.leads_into_work()` (a read-only passthrough of the same check) and
`WorldState._resume_paused_job()`/`_advance_go_to_or_resubmit()` needed the identical correction:
both used to decide "may I call `start_work()` here" off "does this job kind have a work toil
anywhere," which was equally wrong for `build`'s leg one once `work` entered its toils.

`work`'s own progress key (`WorldState._work_progress`, tile-keyed, ADR 009's interrupt/resume
contract) is ordinarily a job's `target` tile, but `build`'s `target` still names the wood item's
own tile (see "Two targets" below), never the site. `ToilExecutor`'s injected `work_target_for`
callable (`WorldState._work_target_for()`) resolves the correct tile everywhere a work-progress
key is read or cleared (`start_work()`, `advance_work_step()`, `_toil_on_work_complete()`,
`_trap_actor()`, `_apply_job_command()`'s terminal cleanup), so an interrupted-and-resumed build
job's partial progress is never read from or cleared against the wrong key.

**Delivery, not a ground drop.** `build` never drives a `place` toil: the wood stays "carried"
(`InventoryType`) through the entire second leg and the timed work phase, and
`WorldState._toil_on_work_complete()`'s own `"build"` case — not a `place`-toil success hook —
consumes it and calls `_set_object()`, the same "work produces an effect" shape
`dig`/`chop`/`mine`/`till`/`sow` already use.

**Two targets, one `JobQueue` field, now native.** `build` needs two destinations: the wood
item's own tile (leg one) and the real build site (leg two, and the tile that must stay
exclusively reserved). `job_queue.gd` is an owned path as of this revision (the round-1
"Known limitations" section below named it as the needed extension point), so `build` gets its
own native fields on the job dict — `site` and `build_kind` — exactly like `HAUL_KIND`'s own
`cell` field, instead of a WorldState-only side table. `job["target"]` still names the item's
tile (mirroring haul's own `target`/`cell` split, and letting `JobQueue`'s ordinary
`_can_reach(job["target"])` reachability check work unmodified); `JobQueue.attach_build()`
(called once, at submission, alongside `attach_item()`) records the site and kind.

**Reservations: activation-owned, not submission-owned.** The round-1 version acquired both
reservations directly in `WorldState._apply_build_submission()`, synchronously, before the job
ever activated. That violated `ReservationInvariants.find_orphaned_reservations()`'s active-owner
requirement for the entire time a submitted job sat queued (labour disabled, no worker free), and
left `JobQueue.suspend()`/`reactivate()` unable to release/reacquire it correctly (`suspend()`
only ever acts on an `"active"` job). `JobQueue._tick_build()` (this revision's own addition,
mirroring `_tick_haul()`'s two-reservation shape but with no destination search — the site is
fixed at submission) now acquires both only on the `queued -> active` transition, exactly like
every other kind's own `tick()` dispatch; `JobQueue._reactivate_build()` mirrors
`_reactivate_haul()` for `suspend()`/resume. Both keys still release together through
`JobQueue._finish()`'s existing `release_all(job_id)` on any cancel/fail/complete.

The site's own reservation uses `JobQueue.TARGET_KEY_PREFIX` ("tile:"), the same namespace an
ordinary dig/chop/mine/till/sow target already uses, so it correctly contends with any other job
kind on the same tile through the one existing ledger.

**The builder always works from an adjacent tile.** A build site is still genuinely passable at
travel time — nothing is placed there until `work` completes — so the ordinary go_to trim rule
(drop the path's last tile only when the target is impassable *right now*) never fires for it,
and a colonist would otherwise walk onto and stand on the exact tile about to become an object.
The `go_to_force_trim_last` hook (`WorldState._toil_go_to_force_trim_last()`,
`ToilExecutor.advance_go_to()`'s `force_trim_last` parameter) forces that trim for **every**
build kind (round 2: uniformly, so the completion rule below can be uniform too), landing the
colonist adjacent exactly like `chop`/`forage`'s own already-impassable target. A builder that is
*already* standing on the site (the stockpile sits on the site itself, or leg one ended there)
has nothing for the trim to drop; `advance_go_to()`'s step-off rule re-aims that same go_to leg
at the first passable orthogonal neighbour (north/west/east/south, the order
`_dig_item_placement()` already uses) through the ordinary route machinery, so no builder ever
runs its work phase on the site.

**Completion re-validates everything submission checked.** `_build_completion_failure()` runs
at the work-complete boundary before anything is placed: the site must still be empty of
objects *and of every actor* (nothing is ever placed over an actor — a passer-by on the site at
the last tick fails the build rather than being walled in), an impassable kind must still not
enclose anything, and the builder must still carry the declared item in at least the declared
quantity. Any refusal fails the job typed (`invalid_target`, `blocked_target_unreachable`,
`blocked_missing_input`) through the same cargo-dropping terminal path an unreachable second leg
uses, so the wood is conserved on the ground and both keys release.

**Exactly the declared quantity is spent.** `_consume_build_cost()` subtracts
`build_cost.quantity` from the carried stack; a remainder goes back to the ground through the
same deposit path every terminal drop uses (`place()` onto the builder's own tile, unconditional
fallback), never destroyed with the rest of the stack.

**Pending orders are commitments.** A queued build holds no reservation yet, but its item and
site are already committed: `_find_available_build_item()` skips every item a queued/active build
names, and `_check_build_command()` refuses a site any pending build already claims
(`_pending_build_jobs()`), so several orders submitted in one tick pick distinct wood and never
share a site.

**Enclosure check.** `_would_enclose()` runs when the target kind's own object definition is
itself impassable (`wall`; `door`/`bed` never trigger it) and, per colony component, compares a
plain 4-connected flood fill of `passable("colony")` tiles from one actor of that component with
and without the candidate tile. Every pending impassable build site already counts as blocked
(the second of two walls ordered into a room's two openings is refused), every colony actor's
component is examined (actors sharing an already-visited component are skipped; one standing on
an impassable tile anchors nothing, so a trapped or disconnected first actor never hides an
enclosure elsewhere), and the same check runs again at completion (topology can change while the
wood is on its way). Rejection is always `blocked_target_unreachable`, the existing typed reason.
An impassable site tile itself (rock, water, trench) is rejected `invalid_target` at submission.

**Preview.** `WorldState.preview()` routes `build` to the same `_check_build_command()`
`apply()` uses (including the stock check), so the toolbar's hover colouring and the click never
disagree; `boot.gd`'s `_command_for_tile()` builds the real command for the three Build tools and
its Cancel tool resolves a build by its construction site (`_order_tile()`), not by the wood tile
its scheduler target names.

**Persistence.** `site`/`build_kind` round-trip through `state_codec.gd`'s `_encode_jobs()`/
`_decode_jobs()` exactly like `itemId`/`cell` already do, and are covered by
`WorldState.state_hash()`'s existing `"jobs"` entry (`get_jobs()` returns the full job dict,
including these two fields, with no separate wiring needed) — an in-flight wall order and an
in-flight bed order at the same tick now hash differently, and a save/load round trip at any
phase (queued, hauling, carrying, mid-search, working) preserves both fields.
`_restore_reroutes()` rebuilds a carrying build's in-flight second-leg search against `job.site`
with the same site-tile exception live execution uses, never against the wood tile. In the
canonical schema and `save_io.gd`'s validator both fields are *optional* on a job — a
same-version save written before `build` existed still loads, with `StateCodec` defaulting them
to `null`/`""` — but mandatory and well-formed on every job of kind `build`, which the validator
rejects otherwise before anything is decoded or ticked. No schema-version bump.

Line-count caps move: `world_state.gd` (2774 in the original slice -> the file's own post-change
line count), `toil_executor.gd` and `job_queue.gd` similarly — each set to the exact post-change
line count, the convention ADR 016/017/018/022/024/026 already established.

## Consequences

- The toil vocabulary still grows by zero verbs; `build` is a pure recombination of
  `reserve`/`go_to`/`pick_up`/`work`/`release_all`, one item (`place`) short of the full six-word
  list the objective allows.
- `_apply_build_submission()` resolves the wood item once, synchronously, at submission --
  unlike haul's own `_tick_haul()` (a per-tick retry loop), a `build` command with no currently-
  available stockpiled item of the declared kind/quantity is rejected outright
  (`blocked_missing_input`) rather than queued to retry once stock arrives. The player re-issues
  the order once the stockpile is restocked. A follow-up wanting haul's own retry-with-backoff
  behaviour for `build` needs its own job-giver module, per Non-goals' own escape hatch.
- `build_cost.quantity` is honoured exactly (a stack of three wood loses one for a wall costing
  one), but the current ground-item model never merges same-kind stacks at spawn, so every
  buildable kind's declared quantity stays 1 today; a single `pick_up` carries one whole stack.
- A build site's own reachability from the colony is never checked at submission (only bounds,
  passability, occupancy, pending claims and enclosure are); an unreachable site is accepted and
  its job later fails typed `blocked_target_unreachable` once its own second-leg route search
  proves it unreachable (`WorldState._toil_on_unreachable()`'s existing `"build"` branch), the
  same outcome shape a second-leg-unreachable haul job already gets.
- A transient occupant on the site at the exact completion tick fails the build (typed, cargo
  conserved) rather than waiting; the player re-issues the order.
- Terminal cargo cleanup for a job suspended by a critical-need interrupt resolves the carrier
  through `_paused_jobs` (`_drop_carried_haul_item()`), for `haul` and `build` alike, and
  deposits the cargo without touching the route/work the need job now owns; a refused resumption
  (`_resolve_refused_reservations()`) drops a build's cargo the same way it already dropped a
  haul's.

## Round-5 review addendum: persisted work-progress ownership

`WorldState._work_progress_owner` (job_id per `_work_progress` tile key, tracked live since the
round-3 revision above) was, until this addendum, never itself persisted: `StateCodec.decode()`
re-derived it after every load by asking "which non-terminal job currently targets this key",
taking whichever job the restored job list happened to visit last. That guess assumed at most one
non-terminal job ever targets a given tile at once — true for two jobs of the *same* kind (their
own submission-time duplicate-target check enforces it) but not across kinds: a `dig` can be
legally submitted and left queued at a `build`'s own site while the build is still actively
working it (dig's target check only cares about tile kind/passability, and reservations are
acquired on activation, not submission — neither rejects it). Loading a save taken in that window
could hand the build's genuine mid-work progress to the unrelated, never-run dig, so cancelling
the dig erased the build's progress and cancelling the build left its own progress abandoned
instead of cleared — neither of which happens on a live, uninterrupted run.

`StateCodec` now persists the exact owner directly: a new optional top-level `workProgressOwners`
field, an array of `{target, jobId}` entries (`_encode_work_progress_owners()`/
`_decode_work_progress_owners()`, `docs/architecture/contracts/game-state.schema.json`'s new
`workProgressOwnerEntry`, `SaveIO._valid_work_progress_owners()`), mirroring `pausedJobs`'
`{colonistId, jobId}` shape and optional-on-the-wire like `digFindRng`/`combatBlockedTargets` — a
same-schema-version addition needing no migration, since `encode()` always writes it now but an
older save simply lacks the field. `WorldState._restore_work_progress_owners()` (replacing the old
guessing `_rebuild_work_progress_owners()`) trusts each persisted job_id directly, cross-checked
against the just-restored job list (must still exist, be `queued`/`active`, and be a kind that
ticks work) so a hand-edited or stale save can never resurrect an owner pointing at a job that is
gone.

**2026-09-23: legacy-save ownership recovery.** A save from before `workProgressOwners` existed
decodes `persisted` as `{}`, but `_work_progress` itself (unconditional on the wire) may still
carry real in-flight progress an active dig/build's own timer, or one a need interrupt suspended
mid-work. Leaving those keys ownerless let them survive forever, since
`_release_owned_work_progress()` only clears a key its own job_id owns: a cancel/fail of the
actual owning job could never match, and a replacement job at the same tile silently inherited
the abandoned timer. `_reconstruct_work_progress_owners()` now recovers ownership from execution
state the save format has always carried, never by guessing from which job merely targets the
key (round-5's own mistake): each colonist's own `work.job_id` for whichever job its currently
active `work` toil belongs to, and `_paused_jobs` for the job_id a need interrupt suspended
mid-work. `_restore_work_progress_owners()` applies this fallback only to a key the persisted map
didn't already resolve, then prunes any `_work_progress` key still without a recovered owner
(excluding an active incident's own job_id-less wait, which never gets a job_id owner by design)
so an unrecovered key cannot leak forward either. A save from before this field existed therefore
now restores with every recoverable owner reattached, not with no owners at all.

Line-count cap moves again: `world_state.gd`'s cap rises to this file's own post-addendum line
count (the doc-comment and restore-function rewrite above), the same convention every prior line
in this ADR's own "Line-count caps move" paragraph already established.

## Round-6 review addendum (second pass): a suspended job's own progress, and a shared arrival bug

Two correctness gaps survived every check above because they only manifest across *two workers*
or *two interrupt kinds*, neither of which any single-colonist build scenario exercises:

**A carrying colonist's own arrival dispatch was selected by a global flag, not the current
job's own toils.** `ToilExecutor`'s `is_first` (which go_to leg is this, for `_arrival_hook()`'s
choice between `start_work` and a no-op) was computed everywhere as `not
InventoryType.is_carrying(colonist)` — correct for `haul`/`build` (the only kinds with a `pick_up`
toil, where "carrying" genuinely means "leg two"), but wrong for every single-leg kind with no
`pick_up` at all (`sleep`, `flee`, `dig`, `chop`, `forage`, `till`, `sow`, `incident`,
`escape_trench`): a colonist interrupted mid-haul/build who still carries its cargo through a
`sleep` or `flee` job (ADR 009's own interrupt boundary keeps cargo through the whole episode)
had that leftover flag misread as "leg two, pick_up already ran", picking the no-op arrival and
never starting the interrupting job's own work timer — it looped arrival forever instead of
resting or fleeing. `ToilExecutor._is_first_leg(toils, colonist)` now decides per the CURRENT
job's own declared toils: `true` unconditionally when `toils` has no `pick_up` at all, falling
back to the carrying flag only for a kind that actually has one. Regression coverage: a real rest
interrupt firing during both haul- and build-carrying (`test_haul_need_interrupt.gd`,
`test_build.gd`), and the equivalent transition into a combat `flee` job while carrying unrelated
cargo (`test_combat.gd`).

**`start_work()`'s resume lookup read the shared tile cache by tile alone, not by job.** A
suspended (still-queued) job's progress stayed in the same `_work_progress`/`_work_progress_owner`
tile-keyed cache the round-5 addendum above persists — fine while only one job at a time ever
targets a given tile, but JobQueue's own activation/reactivation lifecycle (this task's own
Non-goals: build's item/site reservations are acquired and released there, not by
`world_state.gd`) releases a suspended job's site/target reservation the moment it suspends,
letting a *different* job's own `work` toil claim and activate the identical tile. A worker tilling
a tile a suspended `build` had partly worked would inherit the build's leftover ticks as its own
starting point, then overwrite the shared key with its own decreasing count tick by tick, then
erase it outright on its own completion — silently handing one job's timer to another and
discarding the original when the till finished before the build resumed. `_get_work_progress()`
itself is unchanged (tile-only, still the right shape for `escape_trench`'s own "has anything been
stamped here yet" dedup check); a new `_resume_work_progress(target, job_id)` — the actual
`work_progress_get` hook `ToilExecutor.start_work()` now calls with its own `job_id` — is the only
reader that matters here, and a new `_suspend_work_progress(work)` moves a job's own in-progress
timer out of the shared cache into job-id-keyed `_suspended_work_progress` the instant its
colonist's `work` is cleared for any non-terminal reason (a critical-need interrupt, or
`_advance_colonists()`'s own generic per-tick reconciliation), persisted as the optional
`suspendedWorkProgress` field and swept by the same `_release_owned_work_progress()` terminal
boundary a cancelled/failed suspended job already used. `incident`'s own job-id-less stamp (see
the round-5 addendum above) is excluded from this move so its unrelated "clear only an active
job's key" rule stays untouched. `docs/architecture/orders-and-movement.md`'s own work-progress
section and `docs/architecture/save-system.md` describe the persisted shape; `test_build.gd`
covers both ownership orders (a suspended build then an activating till, and the reverse) with a
real second colonist and a save/load taken mid-overlap, and `state_hash()` now includes
`_suspended_work_progress` so two states differing only in it never hash equal.

An unrelated, pre-existing `game/data/tilesets/terrain_tileset.tres` resource-ID rewrite
(Godot's own `--import`/test-run churn, not a real change) was found committed on this branch by
this round's review; it is outside this task's owned paths. It was reverted twice before this
addendum was written and recurred both times regardless, because an automated
"commit work left uncommitted" step re-captured Godot's own regenerated copy of the file from a
later local run before this addendum's claim could be verified against the actual pushed diff.
Round 4's review caught the recurrence and it is reverted again here; the file is not an owned
path and no further edit to it is intended.

## Known limitations

- `game/scripts/viewer/designation_overlay.gd` (not an owned path) draws a pending order at
  `job.target`, which for a build is the wood tile, not the construction site; the toolbar's
  Cancel tool already resolves the site correctly. Cosmetic; a follow-up owning that file should
  read the site the same way `boot.gd`'s `_order_tile()` does.
- The Build tool's toolbar labels are hardcoded English (`data/text/en.json` is not an owned
  path), like the New Game/Debug Scenario buttons before it.

## Round 2 review addendum: blocked-resume cargo conservation, stale preview after a paused click

**Cargo leak when a suspended build's reactivation is refused by a rival job, not a faction
check.** `_check_refused_resumption_returns_cargo()` (above) already covered
`resume_assignment()`'s `not_ordered_by_player` gate, which fails the job outright through
`_resolve_refused_reservations()`. A second, distinct failure mode existed at
`JobQueue.reactivate()`/`_reactivate_build()`: when a different real job claims the build's own
site tile while it sits suspended mid-carry, `reactivate()` returns `false` and
`resume_assignment()` silently no-ops, leaving the job `"queued"` with no scheduler assignment.
`WorldState._resume_paused_job()` had already unconditionally erased its `_paused_jobs` entry
before that outcome was known, so neither `_find_job_colonist()` (no assignment) nor
`_drop_carried_haul_item()`'s suspended-owner fallback (no `_paused_jobs` entry either) could
ever find the carrier again — a later cancel/fail/invalidate on the now-orphaned job left the
wood stuck in the colonist's inventory permanently, outliving the job that "owned" it.

`WorldState._resume_interrupted_job()` now checks the job's own status after calling
`resume_assignment()`: if it is not `"active"` (reactivation failed) and the job is a
`haul`/`build` whose colonist is still physically carrying its cargo, the pause association is
restored (`_paused_jobs[colonist_id] = job_id`) so the suspended-owner path stays valid until a
terminal command or a later successful resumption resolves it. A non-carrying job needs no such
restoration — it is meant to fall to the ordinary fair-queue path, exactly as `resume_assignment`
already documents. `test_build.gd`'s
`_check_blocked_resume_after_rival_claims_site_conserves_cargo()` reproduces the race with a
genuine critical-need interrupt (not a hand-called `_interrupt_current_job()` alone, which stays
eligible for immediate re-selection the very next tick and would simply reclaim its own site
before any rival could) so the colonist is genuinely busy on its own real sleep job while an
unrelated `till` order wins the freed site, then proves the blocked-resume state itself
round-trips through save/load and is still cleanly cancellable afterward with the cargo
conserved exactly once.

**Stale build preview while paused.** `MapView._current_preview_key()` includes
`world.get_tick()`; a successful `build` command does not advance the tick, so while paused the
hovered tile's cache key is identical before and after a click, and `refresh()`'s own
`_update_preview()` cache would skip recomputing the site's validity, leaving it showing the
pre-claim colour. `MapView._commit_build()` now clears `_preview_cache_key` after applying the
command, forcing the next `refresh()` to recompute regardless of tick.

Line-count cap moves again: `world_state.gd`'s cap rises to this file's own post-addendum line
count, the same convention every prior line in this ADR's own "Line-count caps move" paragraph
already established.

## Round 3: build_cost.item joins content reference validation

`game/scripts/core/content/content_registry.gd` (and its test) were added to this task's
`Owned paths` to close the round 2 gap above. `ContentRegistry._check_references()` now walks
every `objects.json` entry's optional `build_cost.item` exactly like a job's `needs_tool`: an id
absent from `items.json` fails construction typed `dangling_reference`, naming `objects.json` and
the offending id, instead of only surfacing later as a runtime `blocked_missing_input`.
`test_content_registry.gd` covers it two ways: the real bundle's own loop now asserts every
declared `build_cost.item` resolves to a declared item, and a new fixture
(`_check_fixture_with_build_cost_dangling_reference_fails_construction()`) proves an unknown id
is rejected the same way `needs_tool`'s existing fixture already is.

This closes a real, live gap, not just a hypothetical one: `content/items.json` never actually
declared `"wood"`, the exact id every buildable object's `build_cost.item` already named — the
real bundle would have failed construction the moment this check went live. `items.json` now
declares `{"id": "wood", "kind": "material"}` alongside `stone`/`sand`/`flint`/`coal`.
