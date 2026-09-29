# ADR 041: `site_fetch`'s `deposit` completion chains onto further same-kind sites

- **Status:** accepted
- **Date:** 2026-09-26
- **Scope:** `deposit`'s own completion decision (`game/scripts/core/world_state.gd`'s
  `_toil_on_deposit_success()`, extended; no change to the `deposit` toil itself,
  `game/scripts/core/jobs/toil_executor.gd`), a new `job_queue.gd` mutator
  (`retarget_site_fetch_site()`), `ConstructionGiver`'s effective fetch sizing
  (`world_state.gd`'s `_toil_pick_up_count_for()` hook, extended -- `construction_giver.gd`
  itself is unchanged and not an owned path for this task),
  `docs/architecture/core-budgets.json`'s cap for `world_state.gd`.
- **Implements:** issue #451 (objective #420, blocked by/extends issue #450's `build_line`).
- **Depends on:** [ADR 038](038-construction-sites.md) (the persistent construction-site
  model, `site_fetch`'s `[reserve, go_to, pick_up, go_to, deposit, release_all]` toils, and
  #400's hands-filling rules this task reuses for source selection) and
  [ADR 036](036-build-multi-source-fetch-efficiency.md) (the deterministic route-cost
  nearest-source search, `_next_site_fetch_source()`, this task adapts to rank sibling
  SITES instead of ground-item sources).

## Context

Before this task, a `site_fetch` job was bound to exactly one construction site for its
whole life: `_toil_on_deposit_success()` unconditionally completed the job the instant its
`deposit` toil succeeded, and `_toil_pick_up_count_for()` clamped every pick_up to exactly
that one site's own remaining need. A colonist whose hands could hold 4 units of wood was
therefore never given more than one site's own declared quantity to carry -- for a
`build_line` wall row of one-quantity blocks, this meant a fresh stockpile trip (fresh
`site_fetch` job, fresh `go_to`/`pick_up` pair) per block, even though a single hands-load
could plainly have served several. Issue #451 asks for the same job, and the same
hands-load, to keep serving further blocks in a row.

## Decision

**On a successful `deposit`, if hands still hold units of the job's own kind, retarget the
SAME job at a further sibling site instead of completing.** `_toil_on_deposit_success()`
now checks `InventoryType.is_carrying(colonist)` and, when true, reads `kind` straight off
`InventoryType.hands_snapshot(colonist)[0]` -- the colonist's own persisted "hands" field,
not the `_site_fetch_picked_kind` runtime cache #400's hands-filling rules maintain for
`_toil_on_pick_up_success()`'s own same-tick use. That cache is explicitly never saved
(round-1 review: it is empty right after any load), so a chain spanning a save/load, or
even just a save taken while mid-walk between hops, would otherwise silently read `kind` as
"" and end the chain early on the very next deposit; hands, by contrast, always hold exactly
what a source item's kind was at pick_up, survive a source item being exhausted and deleted
by that same pick_up, and round-trip through `state_codec.gd`'s existing colonist encoding
unchanged, so this reads correctly whether or not a save/load ever happened in between.
Leftover in hands can only occur when the just-delivered site's own `remaining()` was
smaller than what was held, meaning that site is now fully served for this kind by
construction, so "never re-visits a site it has already fully delivered to" holds without a
separate exclusion. When leftover exists, `_next_site_fetch_site()` (a new query, mirroring
ADR 036/038's own `_next_site_fetch_source()` exactly, applied to
`ConstructionSiteTable.list()` instead of ground items) finds the nearest reachable,
still-short, not-already-at-capacity sibling site by the same deterministic route-cost
search (`_route_cost()`, not open-field Chebyshev, so a candidate ranked nearest is
guaranteed reachable by the identical rule the colonist's own `go_to` toil travels under);
ties break by lowest site id. When one exists, `JobQueue.retarget_site_fetch_site(job_id,
site)` -- a new mutator alongside `retarget_site_fetch_source()` -- stamps both
`job["site"]` (the destination `_toil_site_id_for()`/`_toil_go_to_target()` already read)
and `job["cell"]` (site_fetch's own "delivering" flag, first set equal to `site` by
`mark_site_fetch_delivering()`) with the new site's origin, keeping them in lockstep exactly
as `mark_site_fetch_delivering()` first set them; `item_id`/`target` stay untouched, still
naming the last source visited, exactly as for a job delivering to its very first site. No
new persisted field: `job["site"]` always names whichever site the job is CURRENTLY
delivering to, round-tripping through `state_codec.gd`'s existing whitelist unchanged, and
`state_hash()` already hashes both the `"jobs"` entry and `_sites.list()` directly. The
ordinary per-tick `advance()`/`_next_toil_index()` dispatch then drives a fresh
`go_to`/`deposit` pair at the new site with zero changes to `toil_executor.gd`:
`_toil_is_first_leg()` still reads `job["cell"] != null` (unchanged by retargeting), so the
delivering leg's own existing target/passability/force-trim hooks (`_toil_go_to_target()`,
`_toil_go_to_passable()`, `_toil_go_to_force_trim_last()`) already resolve correctly against
whatever site `job["site"]` currently names.

**When leftover exists but no eligible sibling does, it is dropped before the job
completes, not stranded in hands.** `_toil_on_deposit_success()` calls
`_drop_carried_item_from(colonist)` -- the same live-assignment terminal-drop helper
`cancel_job`/`cancel_site` already call through `_drop_carried_haul_item()` -- immediately
before falling through to `_finish_job()`. Without this, a chain whose remaining sites were
all cancelled or filled by a competing delivery while the colonist still walked toward them
would complete with unused material sealed in hands forever (nothing else ever drains
"hands" once a job is terminal).

**A chain never re-visits a site it has already fully delivered to (by construction, see
above) and never crosses into a different order's tiles**, since `_next_site_fetch_site()`
only ever considers real `ConstructionSiteTable` records, each an independent, disjoint
footprint reservation from every other order.

**A mid-chain critical-need interrupt pauses/resumes at the current leg with no held
material lost, and `cancel_job`/`cancel_site` mid-chain drops exactly what is currently
held, both for free.** Neither path is aware of chaining at all: `JobQueue.suspend()`/
`reactivate()` and the terminal `_finish_job()`/`_drop_carried_haul_item()` paths already
read `job["site"]`/`["cell"]` generically, whatever site those fields currently name --
there is no "original site" bookkeeping anywhere to lose or need restoring, since chaining
never introduced one.

**`_toil_pick_up_count_for()`'s own clamp is widened to size a pick_up for the WHOLE chain
a hands-load could plausibly serve, not just the one site `job["site"]` currently names.**
Before this task, `site_fetch` always requested exactly one site's own remaining need per
pick_up, regardless of kind cardinality -- a colonist could never hold more than one site's
declared quantity, so the chain above could never trigger from a fresh order (there was
never a first delivery with any leftover to chain from). The hook now sums the current
site's own remaining need with every OTHER reachable, still-short sibling site's own
remaining need of the same kind (`_reachable_short_sibling_sites()`, the shared query
`_next_site_fetch_site()` also uses -- which already excludes any sibling already holding
its own `max_builders` worth of queued-or-active fetch-plus-work jobs, see
`_site_fetch_work_busy()` below, so a sibling with no fetch capacity left never inflates a
pick_up beyond what it could ever accept), minus whatever of that kind the colonist's hands
already hold from an earlier hop -- so a hands-load actually carries enough to chain across
several one-quantity blocks in a row, still never past what some real, reachable,
capacity-eligible site could use, so no unit is ever picked up with nowhere to go. This is
the "ConstructionGiver's own submission sizing" the objective calls out: the actual sizing
hook lives in `world_state.gd` (`_toil_pick_up_count_for()`, injected as `pick_up_count_for`
for `ToilExecutor`), not in `construction_giver.gd` itself, which is unchanged (not an owned
path for this task): `ConstructionGiver.advance()` still tops each still-short site's own
fetch-plus-work count up to `max_builders` with fresh `site_fetch` jobs every tick -- never
capped at one submission per site -- but each of those fresh submissions still requires its
own distinct, still-uncommitted source (`_choose_source()`'s `committed_items` guard,
accumulated across the whole `advance()` pass), exactly as ADR 038 decided; only how far one
already-submitted job's own pick_up reaches changed. (See below: a single stockpile stack
backing an entire wall row commits to only the first site whose submission claims it, so most
siblings never get a submission of their own to begin with.)

**This sibling search has no separate item-level exclusion for a site already named by
another pending `site_fetch` job**, unlike `_next_site_fetch_source()`'s own item-level
source exclusion -- because eligibility here is already gated by capacity
(`_site_fetch_work_busy() >= max_builders`, below), not by physical item conflict, and the
capacity gate is the one that actually matters in practice. A single sufficient stockpile
stack backing a `build_line` row of one-quantity blocks does NOT routinely leave every
sibling holding a queued job of its own: `ConstructionGiver._choose_source()` commits that
stack's item id to whichever site's submission claims it first (`committed_items`, tracked
across the whole `advance()` pass), so every other still-short sibling fed from that same
stack gets no fetch job at all until that job's own reservation is actually freed -- its
normal terminal completion (no further eligible sibling to chain onto) or a
`cancel_job`/`cancel_site` mid-chain, either of which runs `release_all()` and drops the
item from `committed_items` on the next `advance()` pass -- or until a second source appears
in the meantime. An intermediate chained deposit does NOT free it: `retarget_site_fetch_site()`
leaves `item_id`/`target` untouched, so the job keeps the same source committed, and
`ConstructionGiver` keeps counting it against `committed_items`, through every hop of the
chain. These job-less siblings are exactly the chain targets this design exists to reach: a
colonist already holding leftover hands-material from an earlier hop reaches them, not a
freed source. A sibling that DOES already hold a job of its own is a different
case: for a `max_builders` 1 site (every wall block), that single queued-or-active job
already saturates `_site_fetch_work_busy()`, so the capacity check below excludes it from
retargeting on its own, with no separate item-level rule needed. For a `max_builders` > 1
site, an existing queued/active job leaves real spare capacity, so a retarget there is
legitimate -- `ConstructionSiteTable.deposit()`'s own clamp to `remaining()` makes two jobs
reaching the same site safe regardless (a site simply accepts nothing further once fully
served, and whichever job arrives second then chains onward in turn via
`_toil_on_deposit_success()`, or completes, rather than stranding cargo in its hands).

**It DOES exclude a site already at its own `max_builders` fetch-plus-work capacity**
(round-1 review), via `_site_fetch_work_busy()` -- the identical queued-or-active
fetch-plus-work count `ConstructionGiver.advance()` itself sums per site before topping it
up with a fresh submission. A retarget never goes through that submission path at all, so
without this explicit check here it could push an already-fully-staffed site over its own
cap; `ConstructionGiver`'s submission-time count alone does not (and cannot) guard against a
retarget it never sees.

## Consequences

- A colonist whose hands hold 4 units of wood can now serve up to 4 one-quantity wall
  blocks from a single hands-load, with no intervening trip to a stockpile, whenever a
  reachable stockpiled stack of that size and enough same-kind short sibling sites both
  exist.
- `world_state.gd`: 4905 -> 5020 lines (+115): `_reachable_short_sibling_sites()`/
  `_next_site_fetch_site()`/`_site_fetch_work_busy()`, `_toil_pick_up_count_for()`'s widened
  sizing, and `_toil_on_deposit_success()`'s chain-or-complete-or-drop decision. Cap raised
  4930 -> 5030 (still within the raised cap after round-1 review's fixes).
- `job_queue.gd`: 755 -> 781 lines (+26): `retarget_site_fetch_site()`. Still within its
  existing 790 cap; no ADR-gated increase needed for this file.
- `toil_executor.gd`: unchanged. The `deposit` toil itself, and every go_to/is_first_leg
  hook it already threads through `hooks`, needed no change: chaining is entirely a
  decision made between two already-existing toil boundaries (a `deposit` succeeding, a
  fresh `go_to` starting), not a new toil or a new hook.
- Two build orders sharing one stockpile (`test_two_site_orders_disjoint_sources_and_
  deterministic`, `test_build.gd`) are unaffected: every fixture item there is a 1-unit
  stack, so the widened pick_up sizing never changes the amount actually moved in one
  `pick_up` call (still bounded by `min(requested, item.count, hands_free)`), and the
  existing hands-filling stop condition in `_toil_on_pick_up_success()` (unchanged, keyed
  to the job's OWN current site alone) already stops hopping the instant hands cover that
  site's own need -- so no leftover, and therefore no chaining, is ever triggered by that
  scenario.

## Alternatives considered

- **Add a new item-level exclusion for a sibling site already named by another pending
  `site_fetch` job**, mirroring `_next_site_fetch_source()`'s own item-level source exclusion
  exactly. Rejected: for a `max_builders` 1 site (every wall block), the existing capacity
  check (`_site_fetch_work_busy() >= max_builders`) already excludes a site holding any
  queued-or-active job of its own from retargeting, so a second, item-level rule would be
  redundant there. For a `max_builders` > 1 site it would be actively wrong, excluding a
  sibling with real spare fetch-plus-work capacity a retarget could legitimately use. Nor
  does a single stockpile stack backing a `build_line` row routinely leave every sibling
  holding a job of its own to begin with: `ConstructionGiver._choose_source()` commits that
  stack's item id to only the first site whose submission claims it, so the row's other
  still-short blocks are typically job-less, not merely-queued -- the capacity gate already
  distinguishes "no room left" from "physically conflicting," which a flat queued-job
  exclusion cannot, and would only ever be actively harmful, never redundantly safe.
- **A persisted `chain: Array[Vector2i]` job field, the whole visiting order resolved once
  up front.** Matches ADR 036's own originally-rejected multi-source design; rejected for
  the identical reason: it would need `state_codec.gd`/`save_io.gd`/the save schema touched
  to survive a save mid-chain, none of which is an owned path for this task, and the
  on-demand, one-decision-per-deposit shape above needs no such field.
- **A new `chain` toil verb** looping `go_to`/`deposit` explicitly in `content/jobs.json`.
  Rejected per this task's own Non-goals ("do not add a new toil verb -- this extends
  `deposit`'s own completion hook"): the existing `[go_to, ..., deposit, release_all]`
  shape already repeats correctly once `_toil_is_first_leg()` keeps reporting `cell !=
  null`, so a new verb would add a vocabulary entry for behaviour the existing one already
  produces once its own completion decision is widened.
