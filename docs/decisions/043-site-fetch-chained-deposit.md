# ADR 043: `site_fetch`'s `deposit` completion chains onto further same-kind sites

> **In short:** A colonist carrying more material than one building needs now drops off the rest at the next building in the row, instead of walking back to the stockpile each time. This makes building a wall of many blocks much quicker.

- **Status:** accepted
- **Date:** 2026-09-26
- **Scope:** `deposit`'s completion decision (`_toil_on_deposit_success()` in
  `game/scripts/core/world_state.gd`, extended; the `deposit` toil in
  `game/scripts/core/jobs/toil_executor.gd` is unchanged), a new `job_queue.gd` mutator
  (`retarget_site_fetch_site()`), the effective fetch sizing (`world_state.gd`'s
  `_toil_pick_up_count_for()` hook, extended; `construction_giver.gd` is unchanged), and
  `docs/architecture/core-budgets.json`'s cap for `world_state.gd`.
- **Depends on:** [ADR 040](040-construction-sites.md) (the persistent construction-site
  model, `site_fetch`'s `[reserve, go_to, pick_up, go_to, deposit, release_all]` toils, and
  the hands-filling rules reused here for source selection),
  [ADR 038](038-build-multi-source-fetch-efficiency.md) (the deterministic route-cost
  nearest-source search that ADR 040's `_next_site_fetch_source()` uses, adapted here to rank
  sibling *sites* instead of ground-item sources), and
  [ADR 042](042-build-line-batch-command.md) (`build_line`, which creates the rows of sites
  this chaining serves).

## Context

Previously, a `site_fetch` job was bound to exactly one construction site for its whole life:
`_toil_on_deposit_success()` completed the job as soon as its `deposit` toil succeeded, and
`_toil_pick_up_count_for()` clamped every `pick_up` to that one site's remaining need. A
colonist whose hands could hold 4 units of wood was therefore never given more than one site's
declared quantity to carry. For a `build_line` wall row of one-quantity blocks, this meant a
fresh stockpile trip (a new `site_fetch` job, with a new `go_to`/`pick_up` pair) per block, even
though a single hands-load could have served several. This change lets the same job, with the
same hands-load, keep serving further blocks in a row.

## Decision

**On a successful `deposit`, if hands still hold units of the job's kind, retarget the same job
at a further sibling site instead of completing it.** `_toil_on_deposit_success()` checks
`InventoryType.is_carrying(colonist)` and, if true, reads `kind` from
`InventoryType.hands_snapshot(colonist)[0]`, the colonist's persisted `hands` field. It does not
use the `_site_fetch_picked_kind` runtime cache that the hands-filling rules maintain for
`_toil_on_pick_up_success()`'s same-tick use: that cache is never saved and is empty right after
any load, so a chain spanning a save/load (or a save taken mid-walk between hops) would read
`kind` as `""` and end the chain early at the next deposit. Hands always hold exactly the kind
picked up, survive the source item being exhausted and deleted by that `pick_up`, and round-trip
through `state_codec.gd`'s existing colonist encoding, so this is correct whether or not a
save/load happened in between.

Leftover in hands can only occur when the just-delivered site's `remaining()` was smaller than
what was held, which means that site is now fully served for this kind. So "never re-visit a
site already fully delivered to" holds without a separate exclusion. When there is leftover,
`_next_site_fetch_site()` (a new query that mirrors `_next_site_fetch_source()` but ranks
`ConstructionSiteTable.list()` instead of ground items) finds the nearest reachable,
still-short, not-at-capacity sibling site using the same deterministic route-cost search
(`_route_cost()`, not open-field Chebyshev distance, so a candidate ranked nearest is
guaranteed reachable by the same rule the colonist's `go_to` toil travels under). Ties break by
lowest site id.

When a sibling exists, `JobQueue.retarget_site_fetch_site(job_id, site)`, a new mutator
alongside `retarget_site_fetch_source()`, sets both `job["site"]` (the destination
`_toil_site_id_for()` and `_toil_go_to_target()` read) and `job["cell"]` (`site_fetch`'s
"delivering" flag, first set equal to `site` by `mark_site_fetch_delivering()`) to the new
site's origin, keeping them in step as `mark_site_fetch_delivering()` first set them.
`item_id`/`target` are unchanged and still name the last source visited, exactly as for a job
delivering to its first site. There is no new persisted field: `job["site"]` always names the
site the job is *currently* delivering to and round-trips through `state_codec.gd`'s existing
whitelist, and `state_hash()` already hashes both the `"jobs"` entry and `_sites.list()`. The
ordinary per-tick `advance()`/`_next_toil_index()` dispatch then drives a fresh `go_to`/`deposit`
pair at the new site with no change to `toil_executor.gd`. `_toil_is_first_leg()` still sees
`job["cell"]` set (retargeting never clears it), so the delivery leg's existing target,
passability, and force-trim hooks (`_toil_go_to_target()`, `_toil_go_to_passable()`,
`_toil_go_to_force_trim_last()`) resolve against whatever site `job["site"]` currently names.

**When there is leftover but no eligible sibling, it is dropped before the job completes rather
than stranded in hands.** `_toil_on_deposit_success()` calls `_drop_carried_item_from(colonist)`,
the same live-assignment terminal-drop helper `cancel_job`/`cancel_site` reach through
`_drop_carried_haul_item()`, immediately before `_finish_job()`. Without this, a chain whose
remaining sites were all cancelled, or filled by a competing delivery while the colonist was
walking, would complete with unused material held forever, since nothing drains `hands` once a
job is terminal.

**A chain never crosses into a different order's tiles**, since `_next_site_fetch_site()`
considers only real `ConstructionSiteTable` records, each with its own footprint reservation
disjoint from every other order's.

**Interrupts and cancellation need no chaining-specific handling.** A mid-chain critical-need
interrupt pauses and resumes at the current leg with no held material lost, and
`cancel_job`/`cancel_site` mid-chain drops exactly what is currently held. `JobQueue.suspend()`/
`reactivate()` and the terminal `_finish_job()`/`_drop_carried_haul_item()` paths already read
`job["site"]`/`["cell"]` generically, whatever site they currently name; there is no "original
site" bookkeeping to lose or restore.

**`_toil_pick_up_count_for()` sizes a `pick_up` for the whole chain a hands-load could serve, not
just the current site.** Previously `site_fetch` always requested exactly one site's remaining
need per `pick_up`, so a colonist never held more than one site's declared quantity and a chain
could never start from a fresh order (the first delivery never left any leftover). The hook now
sums the current site's remaining need with the remaining need of every *other* reachable,
still-short sibling site of the same kind (`_reachable_short_sibling_sites()`, the query
`_next_site_fetch_site()` also uses), minus what the colonist already holds of that kind from an
earlier hop. That query already excludes siblings at their `max_builders` fetch-plus-work capacity
(see `_site_fetch_work_busy()` below), so a sibling with no capacity left never inflates a
`pick_up`. A hands-load therefore carries enough to chain across several one-quantity blocks,
but never more than some real, reachable, capacity-eligible site could use, so no unit is picked
up with nowhere to go. This hook, injected into `ToilExecutor` as `pick_up_count_for`, is where
the effective fetch sizing lives; `construction_giver.gd` is unchanged.
`ConstructionGiver.advance()` still tops each still-short site's fetch-plus-work count up to
`max_builders` with fresh `site_fetch` jobs every tick (never capped at one submission per
site), and each fresh submission still needs its own distinct, uncommitted source
(`_choose_source()`'s `committed_items` guard, accumulated across the whole `advance()` pass), as
ADR 040 decided. Only how far one already-submitted job's `pick_up` reaches has changed.

**The sibling search has no item-level exclusion for a site already named by another pending
`site_fetch` job**, unlike `_next_site_fetch_source()`'s item-level source exclusion. Eligibility
here is gated by capacity (`_site_fetch_work_busy() >= max_builders`, below), not by physical item
conflict, and capacity is the gate that matters in practice. A single sufficient stockpile stack
backing a `build_line` row of one-quantity blocks does *not* routinely leave every sibling with a
queued job: `ConstructionGiver._choose_source()` commits that stack's item id to whichever site's
submission claims it first (`committed_items`), so every other still-short sibling fed from that
stack gets no fetch job until the job's reservation is freed or a second source appears. The
reservation is freed by the job's normal completion (no further eligible sibling) or by
`cancel_job`/`cancel_site` mid-chain; either runs `release_all()`, and the item drops out of
`committed_items` on the next `advance()` pass. An intermediate chained deposit does *not* free
it: `retarget_site_fetch_site()` leaves `item_id`/`target` unchanged, so the job keeps the same
source committed through every hop. These job-less siblings are exactly the targets chaining
exists to reach, using the leftover material from an earlier hop rather than a freed source. A
sibling that already has a job of its own is a different case. For a `max_builders: 1` site
(every wall block), that single queued or active job already saturates `_site_fetch_work_busy()`,
so the capacity check excludes it without any item-level rule. For a `max_builders` > 1 site, an
existing job leaves real spare capacity, so a retarget there is legitimate.
`ConstructionSiteTable.deposit()`'s clamp to `remaining()` makes two jobs reaching the same site
safe regardless: the site accepts nothing once fully served, and whichever job arrives second
chains onward via `_toil_on_deposit_success()`, or completes, rather than stranding cargo.

**The search does exclude a site already at its `max_builders` fetch-plus-work capacity**, via
`_site_fetch_work_busy()`, the same queued-or-active fetch-plus-work count
`ConstructionGiver.advance()` sums per site before topping it up. A retarget never goes through
that submission path, so without this check it could push a fully staffed site over its cap;
`ConstructionGiver`'s submission-time count cannot guard against a retarget it never sees.

## Consequences

- A colonist whose hands hold 4 units of wood can serve up to 4 one-quantity wall blocks from a
  single hands-load, with no intervening stockpile trip, whenever a reachable stockpiled stack of
  that size and enough same-kind short sibling sites both exist.
- `world_state.gd`: 4905 -> 5020 lines (+115) for `_reachable_short_sibling_sites()`,
  `_next_site_fetch_site()`, `_site_fetch_work_busy()`, `_toil_pick_up_count_for()`'s widened
  sizing, and `_toil_on_deposit_success()`'s chain, complete, or drop decision. The cap is raised
  from 4930 to 5030.
- `job_queue.gd`: 755 -> 781 lines (+26) for `retarget_site_fetch_site()`, within its existing
  790 cap, so no budget increase is needed for this file.
- `toil_executor.gd`: unchanged. Neither the `deposit` toil nor any `go_to`/`is_first_leg` hook it
  threads through `hooks` needed changing: chaining is a decision made between two existing toil
  boundaries (a `deposit` succeeding and a fresh `go_to` starting), not a new toil or hook.
- Two build orders sharing one stockpile (`test_two_site_orders_disjoint_sources_and_deterministic`
  in `test_build.gd`) are unaffected. Every fixture item there is a 1-unit stack, so the widened
  sizing never changes the amount one `pick_up` call moves (still bounded by
  `min(requested, item.count, hands_free)`), and the unchanged hands-filling stop condition in
  `_toil_on_pick_up_success()`, keyed to the job's current site alone, stops hopping as soon as
  hands cover that site's need. No leftover, and therefore no chaining, arises in that scenario.

## Alternatives considered

- **Add an item-level exclusion for a sibling site already named by another pending `site_fetch`
  job**, mirroring `_next_site_fetch_source()`'s item-level source exclusion. Rejected. For a
  `max_builders: 1` site (every wall block), the capacity check (`_site_fetch_work_busy() >=
  max_builders`) already excludes a site with any queued or active job, so the extra rule would be
  redundant. For a `max_builders` > 1 site it would be wrong, excluding a sibling with real spare
  capacity a retarget could legitimately use. And since `ConstructionGiver._choose_source()`
  commits a shared stack to only the first site that claims it, a row's other still-short blocks
  are typically job-less rather than merely queued. The capacity gate distinguishes "no room left"
  from "physically conflicting"; a flat queued-job exclusion cannot, and could only cause harm.
- **A persisted `chain: Array[Vector2i]` job field with the whole visiting order resolved up
  front.** This matches ADR 038's rejected persisted-plan design and is rejected for the same
  reason: surviving a save mid-chain would require changing `state_codec.gd`, `save_io.gd`, and
  the save schema, whereas the on-demand, one-decision-per-deposit approach needs no new field.
- **A new `chain` toil verb** looping `go_to`/`deposit` explicitly in `content/jobs.json`.
  Rejected: the change is scoped to extending `deposit`'s completion hook, not adding a toil verb.
  The existing `[go_to, ..., deposit, release_all]` shape already repeats correctly while
  `_toil_is_first_leg()` keeps seeing `cell` set, so a new verb would add vocabulary for behaviour
  the existing one already produces once its completion decision is widened.
