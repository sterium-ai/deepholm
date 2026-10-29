# ADR 055: One read-only view snapshot per viewer refresh

> **In short:** The viewer now reads the world once per refresh, through
> `WorldState.get_view_snapshot(detail_ids)`, instead of calling a handful of getters that
> each copied every colonist. The snapshot keeps one column per fact the map and the lists
> need, plus a full copy of only the colonists whose panel rows are being rewritten that
> tick. Everything in it is read-only. It is never saved or hashed.

- **Status:** accepted
- **Date:** 2026-10-28
- **Scope:** simulation (public read surface of `WorldState`), presentation (every viewer refresh)
- **Depends on:** ADR 048 (composed core, size budgets), ADR 012 (actor table and components),
  ADR 037 (the "carrying" view of hands)
- **Implements:** BACKLOG A9; `docs/architecture/simulation-boundaries.md` ("Inputs and outputs")

## Context

At 1,000 actors one viewer refresh took about 415 ms (A9's `bench_viewer_refresh`, on `main`
at `e1b71f8`). The viewer called `get_colonists()` (a deep copy of every worker) from the
colonist sprites, the colonist panel (once per row for the recruit check, so N² copies), the
work table, the need alerts and the map's colour mode, plus `get_actors_with_health()`,
`get_assignments()` once per panel row, `get_job()` per working colonist, and
`get_items()`/`get_zones()`/... on every draw. The colonist panel freed and recreated every
row each tick, and each colonist drew as four to six nodes.

A single deep copy of every actor per tick was measured at about 9 ms for 1,000 actors, and
freezing it (making every nested container read-only) about 11 ms more. Every actor's record
also changes every tick (its need accumulators), so caching copies by content does not help.

## Decision

`WorldState.get_view_snapshot(detail_ids: Array = []) -> Dictionary` is the viewer's read
surface for a refresh. It is built by `game/scripts/core/world/view_snapshot.gd`, a static
module that receives the live actor table and `WorldState`'s getters as arguments (it never
holds `WorldState`). Its keys are documented at the top of that file. In short:

- **Columns.** One read-only `Array` per per-actor fact the map and the lists need (`ids`,
  `kinds`, `factions`, `x`, `y`, `worker`, `carrying`, `tool_kinds`, `trapped`, `work_kinds`,
  `hp`, `max_hp`), in actor-table order, plus `workers_by_id` (the worker rows sorted by id).
  They are `Array`s, not `Packed*Array`s, because a packed array is shared by reference and
  cannot be made read-only (a test showed a viewer write reaching the snapshot); a reader that
  wants packed speed assigns a column to a `Packed*Array` variable and gets its own copy.
- **Details.** A frozen `get_colonists()`-shaped copy of each worker named in `detail_ids`,
  and, for those workers only, their `get_assignments()` entries, the jobs their assignment,
  route, work or pending need job names (`get_job()` copies, all sharing one assignments
  copy), their pending need job ids and their rescue reasons.
- **Once-per-refresh copies** of `get_queued_job_summary()`,
  `get_tool_items()`, `get_items()`, `get_construction_sites()`, `get_zones()`,
  `get_pending_trade_offers()` and the need reasons.

Every `Dictionary` and `Array` in the snapshot is read-only, so a viewer bug that writes to
it fails loudly instead of drifting. It is not simulation state: never persisted, never in
`state_hash()`, and taking one changes nothing (the worker-roster sort is memoised in a
static of `view_snapshot.gd`, a pure function of the ids and worker columns).

On the viewer side, `boot.gd` takes one snapshot per refresh, asking for the details of the
colonist panel's current window of rows (`InfoPanel.detail_ids()`), and hands it to the map
view, both panels and the need alerts. A layer or panel called on its own (tests, a click
handler) takes its own snapshot.

`get_colonists()` keeps its shape and now builds its copies with the same
`ViewSnapshot.actor_copy()`. The viewer's two private reads, `world._content.list(...)` in
`control_bar.gd` and `order_input.gd`, go through a new `get_content_list(kind)` (the
registry's own read-only list), and the viewer-purity rule now rejects any `world._x` read or
write in the viewer and `boot.gd`.

## Alternatives considered

- **A full deep copy per refresh, frozen.** Simplest contract, but about 20 ms at 1,000
  actors before the viewer does any work (see Context).
- **A shallow copy per actor.** Cheap, but its nested containers (needs, route, hands) would
  still be the live ones: neither read-only nor stable across a tick.
- **Caching copies until an actor changes.** Every actor changes every tick (need
  accumulators); a dirty flag would have to be set by every core system that writes an actor.
- **A lazy `actor(id)` accessor on a snapshot object.** It would read live state after the
  fact, so two readers in one refresh could see different worlds.

## Consequences

- The per-tick viewer refresh at 1,000 actors drops from about 415 ms to about 3.2 ms (mean;
  2.9–3.6 ms per run with the UI laid out and 3 colonist rows on screen; p95 4.1–4.5 ms;
  `docs/orca/handoffs/A9.md` has the numbers and the command).
- `WorldState.get_job()` takes an optional `assignments` copy, so the snapshot's job lookups
  share one instead of each deep-copying every assignment for the tool-handover overlay.
- A colony of `ColonistPanel.ALL_ROWS_UP_TO` (16) or fewer sees every line every tick, as
  before. In a larger one a tick recomposes every row on screen, any new or rebuilt row, and
  `ColonistPanel.ROWS_PER_REFRESH` (4) more in a window that walks the id-sorted roster; at
  1,000 colonists a row off screen is at most 250 ticks old. A refresh at the same tick as the last
  one (it follows a command or a world swap, also while paused) recomposes every row, so a
  command's effect shows at once anywhere in the list; at 1,000 colonists that refresh costs
  about 33 ms. Scrolling or resizing the panel recomposes, at once, every row that comes on
  screen with a line older than the current tick, so a stale row is never shown, also while
  paused. The work table compares only the rows whose details the snapshot carries;
  labour levels change only through `set_labour`, and its own clicks refresh their row at once.
- The map layers keep no node per actor: colonist and actor sprites are plain records drawn by
  one `_draw()` per layer, and a colonist whose columns did not change is skipped.
- A new reader needs a field the snapshot lacks: add a column (if every actor needs it each
  tick) or read it from the details, and update `view_snapshot.gd`'s key list and
  `test_viewer_snapshot.gd`.
- `TickDriver` now runs at most `MAX_TICKS_PER_FRAME` (4) ticks per frame and drops the rest of
  a long frame's backlog, so a slow frame cannot snowball; the simulation then runs slower
  than the chosen speed, never faster. This is presentation timing only; the tick rule is
  unchanged.

## Acceptance criteria

- [x] The affected canonical document is updated (`simulation-boundaries.md`).
- [x] Contracts, examples, and tests are updated: `test_viewer_snapshot.gd` (new),
  `test_architecture_rules.gd` (private-member rule with a planted read), the sprite and panel
  tests for the new records; no JSON contract changes (N/A).
- [x] Save/migration impact is handled: none, the snapshot is never persisted.
- [x] The source-of-truth index still points to the authoritative location (unchanged).
