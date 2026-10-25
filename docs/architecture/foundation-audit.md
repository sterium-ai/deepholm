# Foundation audit: can this base carry the long-term ambition?

> **In short:** The rules of the game are written well: deterministic, tested,
> data-driven and cleanly separated from the display. The machinery that runs
> those rules does not yet scale. It copies whole collections every tick, has
> no spatial index, keeps every finished job and event forever, and searches
> routes with a slow Dijkstra that allocates on every step. Measured on a fast
> desktop, one tick takes 1.9 s with 1,000 idle colonists and 4.5 s when they all
> have work. The game runs 2 ticks per second at normal speed. Ten colonists also
> slow down when a large field is designated at once. Several limits are hard-wired: one
> map layer, one content folder, no scenario, story or translation layer, and
> a Web-only export. None of this needs a rewrite. Each limit has a bounded
> fix, listed as an `A*` task in `docs/orca/BACKLOG.md`. The owner accepted all of
> them on 2026-10-25.

Audit date: 2026-10-25, at `main` `052d8c4` (Phase R through R3; `world_state.gd` is 4,290
lines). This page is the evidence. A plain-language summary for the owner, in Spanish, is
[foundation-audit-summary.md](foundation-audit-summary.md).

## 0. Method and how to reproduce

- **Code claims** cite a path and a function (and a line where that helps) at `052d8c4`.
  Line numbers drift; the function name is the stable anchor.
- **Performance claims** come from the committed headless benchmarks
  `game/scripts/tests/bench_*.gd`. The test runners only glob `test_*.gd`, so the suite never
  runs them. They are evidence, not a performance gate: they exit 0, except that
  `bench_tick_scaling.gd` exits 1 when its correctness check (below) fails.
- **Host:** AMD Ryzen 7 9800X3D (8 cores, 16 threads), Windows 11, Godot 4.7.2 headless,
  single-threaded simulation. This is a fast desktop CPU, so a phone will be several times
  slower. That factor is not measured here (see §3.8).
- **Reproduce everything** (about 15 minutes; run nothing else heavy meanwhile):

  ```powershell
  docs\orca\handoffs\A0-run-benches.ps1 -Out bench-results.txt
  # or one benchmark:
  & $env:GODOT --headless --path game --script res://scripts/tests/bench_tick_scaling.gd
  & $env:GODOT --headless --path game --script res://scripts/tests/bench_tick_scaling.gd -- --actors=10,100 --ticks=20 --workloads=idle
  ```

  The raw output of the run quoted here is in `docs/orca/handoffs/A0-bench-results.txt`.

| Benchmark | What it measures |
| --- | --- |
| `bench_tick_scaling.gd` | `tick()` time against 10/100/500/1000 colonists on a generated 256×256 map for idle and busy (one till order each), and 10/25/50/100 for everyone thirsty at once, with a per-phase split |
| `bench_long_session.gd` | tick time against play time (finished jobs piling up) and against the size of the open order backlog, at 10 colonists |
| `bench_route_search.gd` | `RouteSearch` cost against path distance on the real map and on an open grid, the unreachable worst case, region build and region update |
| `bench_save_load.gd` | save/load size and time against actor count, and whether a dropped `WorldState` is freed |
| `bench_content_load.gd` | `ContentRegistry` load time for the real bundle and for +100/+1,000/+5,000 synthetic items and objects |
| `bench_common.gd` | shared helpers, including `profiled_tick()`: `tick()`'s calls in the same order with a timer per phase |

**Is the per-phase split trustworthy?** Each `bench_tick_scaling` run advances a twin world
with the real `tick()` and prints `hash_match`. It was `true` in every run quoted here, so
`profiled_tick()` executes exactly what `tick()` executes. A mismatch makes the benchmark
print `FAILED hash check` and exit 1.

**What is not measured:** rendering and frame time (a headless run has no GPU), memory
peaks, and phone CPUs. The benchmarks seat N colonists by cloning the generator's
`colonist_0`, so all of them share the same needs and labour table, as a fresh colony does.

## 1. Verdict per axis

The tick budget used below: at normal speed the viewer runs 2 ticks per second, and 6 at
×3 (`viewer/tick_driver.gd`). The simulation runs on the main thread, so a tick slower than
one frame (about 16 ms) is a visible hitch, and a tick slower than 167 ms cannot keep up at
×3.

| Axis | Today | Breaks first | Smallest structural change | Tasks |
| --- | --- | --- | --- | --- |
| 1,000+ actors | 10 colonists ≈ 1–2.5 ms per tick; 100 ≈ 28–55 ms; 1,000 ≈ 1.9–4.5 s. A shared thirst onset: 1.6 s at 10 colonists, 153 s at 100 | need-source search O(W·A²), combat targeting O(A²), then scheduler/route search, per-colonist O(A·J) lookups | per-region need candidates and a spatial index; allocation-free map queries; heap route search; job id index and read-only views | A2–A5, A8 |
| Long sessions | finished jobs, both event logs and dirty cells never shrink; the open backlog drives tick time | `get_jobs()` deep copies over a growing list; per-emit sort | bounded job history; cursor-based streams | A5, A6 |
| Map layers | single 2D grid, 506 `Vector2i` sites, 4 key formats | everything assumes one layer | coordinate-model ADR before F4; one key helper | A12 (+A2) |
| Hundreds of content kinds | registry, schemas and components are good; load is linear, about 90 µs per entry | behaviours hard-coded per kind (`_toil_on_work_complete()`); save validator repeats content | data-driven work effects; whitelists from the registry | A13, A14 |
| Stories, events, quests | incidents with a daily budget only | no triggers, conditions, flags or quest state | story giver ADR (trigger → condition → effect as commands) | A17 |
| Scenarios and levels | none; `debug_scenario.gd` is code | no scenario format | `scenarios.json` with a schema | A16 |
| Localisation | key-based `TextTable` exists | English in core messages and viewer literals; no locale | codes only from the core; all text by key; locale fallback | A15 |
| Mods and data packs | one content folder | no roots, order or override; duplicate ids overwrite silently; registry rebuilt per save | one registry per session from ordered roots | A13 |
| Mobile | `gl_compatibility` renderer, ADR 003 rules | Web-only export, no touch, main-thread tick and save, never measured on a phone | measured spike, then a threading ADR | A18 (+A7, A9) |
| Tooling and hygiene | 90 headless tests, determinism tests | no replay tool, no typing gate, no perf baseline, worlds leak | replay recorder; warnings gate; bench runner; `dispose()` | A1, A7, A10, A11 |

## 2. Measurements

All numbers come from `docs/orca/handoffs/A0-bench-results.txt`: one run, on the host in §0,
on `main` `052d8c4` plus this change's files. An earlier run on `e0a9f56`, before R3, agreed
within about 10% on most lines and up to 25% on a few 100-colonist rows. During both runs, other Godot processes were also
running on the same machine: the owner's game window and two other agent worktrees. The benchmarks are single-threaded on a 16-thread
CPU, so treat every number as ±25%.

### 2.1 Tick time against actor count (`bench_tick_scaling.gd`)

256×256 map, seed 42. The numbers are the real `tick()`: mean over ticks 2–30 (2–20 for
busy/1,000, where the 90 s budget ended the run), with tick 1 shown separately.

| Colonists | idle: mean (tick 1) | busy: mean (tick 1) |
| --- | --- | --- |
| 10 | 1.04 ms (291 ms) | 2.42 ms (349 ms) |
| 100 | 28.4 ms (359 ms) | 55.3 ms (445 ms) |
| 500 | 473 ms (844 ms) | 1,499 ms (2,015 ms) |
| 1,000 | 1,879 ms (2,377 ms) | 4,544 ms (5,648 ms) |

`needs` workload (every colonist's water at 20, below `urgent`, at tick 0; re-run after
review, see the note in the results file):

| Colonists | tick 1 | of which `need_giver` | mean, ticks 2–30 | `need_giver`, ticks 2–30 |
| --- | --- | --- | --- | --- |
| 10 | 2,010 ms | 1,628 ms | 9.2 ms | 7.8 ms |
| 25 | 9,782 ms | 9,585 ms | 23.9 ms | 19.2 ms |
| 50 | 37,794 ms | 38,170 ms | 50.9 ms | 45.1 ms |
| 100 | 147,658 ms | 153,395 ms | not measured (tick 1 exceeded the 90 s run budget) | — |

(Tick 1 is timed separately on the real and profiled worlds, so `need_giver` can exceed the
real tick by a few percent.)

Largest phases (ms per tick, ticks 2..n, from `profiled_tick()`; `hash_match=true` in every
run):

| Run | combat | scheduler | advance_colonists | rescue_giver | needs_decay | others |
| --- | --- | --- | --- | --- | --- | --- |
| idle 100 | 18.8 | 1.3 | 0.5 | 1.3 | 2.3 | < 1.1 each |
| idle 1,000 | **1,787.8** | 19.1 | 7.0 | 96.0 | 23.3 | calendar_alerts 12.3 |
| busy 100 | 19.0 | 8.0 | **33.7** | 1.3 | 2.3 | haul 1.5, construction 1.5 |
| busy 500 | 400.3 | 332.6 | **667.5** | 22.5 | 11.1 | haul 13.5, construction 13.1 |
| busy 1,000 | 1,634.1 | **2,186.3** | 582.1 | 88.8 | 22.3 | haul 14.3, construction 13.0 |

Reading: combat grows with A² (18.8 → 1,788 ms for 10× the actors) and dominates as soon as
there are hundreds of actors, even with no hostiles on the map. With work, the scheduler and
per-colonist toil advance grow faster than linearly. Tick 1 pays 280–450 ms of lazy
region building at any actor count. The needs table is the worst result of the audit: a
synchronised need onset costs O(W·A²) (§3.1, item 1).

### 2.2 Tick time against play time and open backlog (`bench_long_session.gd`, 10 colonists)

| Retention (backlog kept at about 20 open orders) | 1,000 | 2,000 | 3,000 | 4,000 | 5,000 | 6,000 ticks |
| --- | --- | --- | --- | --- | --- | --- |
| mean tick (ms) | 17.5 | 15.3 | 14.6 | 20.2 | 19.7 | 25.3 |
| jobs in `_jobs` (terminal) | 149 (129) | 229 (204) | 296 (280) | 374 (353) | 428 (410) | 498 (479) |
| `JobQueue._events` / `EventLog._events` | 685 / 1,834 | 1,061 / 3,281 | 1,594 / 4,900 | 2,366 / 6,744 | 2,974 / 8,402 | 3,706 / 10,198 |

| Open orders at once | 0 | 100 | 500 | 2,000 |
| --- | --- | --- | --- | --- |
| mean tick (p50, max) | 1.62 ms (1.64, 1.8) | 38.8 ms (3.3, 1,262) | 54.3 ms (16.6, 1,385) | 234.8 ms (194.4, 1,582) |
| slowest phase | combat 0.47 | advance_colonists 35.8 | advance_colonists 38.0 | scheduler 174.0 |

Reading: everything that is never trimmed grows linearly with play time. Tick time grows
too, by about 45% over 6,000 ticks (a 50-minute session at ×1), though noisily. Most of
the steady cost at 10 colonists is `advance_colonists`, which is route searching during
movement. The backlog matters more: a player designating 2,000 tiles makes 10 colonists
tick about 145 times slower than an idle colony. The 1-second single ticks are the room re-flood
in §3.1, item 4.

### 2.3 Route search (`bench_route_search.gd`)

| Map, path distance | expansions | ticks to route (64 per tick) | time | µs per expansion | snapshot JSON |
| --- | --- | --- | --- | --- | --- |
| generated, 8 | 79 | 2 | 0.51 ms | 6.5 | 3.7 KB |
| generated, 32 | 1,728 | 27 | 17.6 ms | 10.2 | 60 KB |
| generated, 64 | 4,482 | 71 | 37.5 ms | 8.4 | 145 KB |
| generated, 128 | 8,423 | 132 | 74.5 ms | 8.9 | 270 KB |
| generated, 256 | 15,462 | 242 | 125.4 ms | 8.1 | 471 KB |
| open grid, 32 | 497 | 8 | 1.58 ms | 3.2 | 14 KB |
| open grid, 128 | 8,129 | 128 | 53.5 ms | 6.6 | 236 KB |
| open grid, 256 | 32,641 | 511 | 365.4 ms | 11.2 | 1.0 MB |
| open grid, 384 | 57,281 | 896 | 648.5 ms | 11.3 | 1.8 MB |
| open grid, unreachable | 65,531 | 1,024 | 868.9 ms | 13.3 | 2.1 MB |

Regions and rooms (`map/regions.gd`, `map/rooms.gd`) are below. The generated-map rows go
through `passability()`.

| Operation | time |
| --- | --- |
| regions full build, generated map (`TileGrid.get_regions()`) | 345 ms |
| regions full build, open grid, array callable | 148 ms |
| regions `on_passability_changed`, block one tile in an open 256×256 region | 153 ms |
| regions `on_passability_changed`, unblock it | 0.03 ms |
| rooms full build, generated map (`TileGrid.get_rooms()`) | 902 ms |
| rooms `on_passability_changed` with no passability change (open area) | 98 ms |

Reading: expansions grow with distance squared, because Dijkstra has no heuristic. The cost
per expansion also rises with frontier size, because of the linear pop (3.2 µs at d=32,
13.3 µs exhausting the map). The array-cost grid is only somewhat cheaper per expansion than
`passability()`, so the algorithm's own allocation (neighbour array plus lambda sort) costs
as much as the map query. A mid-search route snapshot is saved in full (§4.4) and reaches
2 MB of JSON. Blocking one tile in a large open region re-floods the region (153 ms), so
placing a wall in an open field costs a frame-time hitch per wall.

### 2.4 Save and load (`bench_save_load.gd`; one till order each, 10 ticks run first)

| Colonists | file | encode | `write_atomic` | read + integrity | decode | save total | load total | round trip `state_hash` |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 10 | 477 KB | 20 ms | 447 ms | 352 ms | 500 ms | 466 ms | 852 ms | equal |
| 100 | 573 KB | 24 ms | 743 ms | 549 ms | 702 ms | 768 ms | 1,251 ms | equal |
| 1,000 | 1,408 KB | 54 ms | 1,923 ms | 1,401 ms | 697 ms | 1,976 ms | 2,098 ms | equal |

- **Inside `write_atomic` at 1,000 colonists:** `_validate_state` takes 142 ms (it builds a
  `ContentRegistry` from disk) and one `JSON.stringify` takes 60 ms. `write_atomic`
  stringifies three times, parses once and re-reads the file.
- **Largest sections at 1,000 colonists:** `entities` 462 KB, `map.tiles` 451 KB, `jobs`
  191 KB, `scheduling.pending` 114 KB.
- **At 10 colonists**, `map.tiles` alone is 451 of 477 KB.
- **Leak check:** dropping three `WorldState`s left 96 more live Objects, 32 per world.
  The worlds are not freed (§4.2).

### 2.5 Content load (`bench_content_load.gd`)

| Bundle | bytes | `ContentRegistry.new()` |
| --- | --- | --- |
| real (9 items, 10 objects) | 13 KB | 18.8 ms mean of 5 |
| +100 items, +100 objects | 48 KB | 35.6 ms |
| +1,000 items, +1,000 objects | 348 KB | 203 ms |
| +5,000 items, +5,000 objects | 1.69 MB | 876 ms |

Load cost is linear, about 90 µs per added entry. For comparison, Godot's native
`JSON.parse_string` reads the +5,000 bundle's `objects.json` (1.33 of the 1.69 MB) in
23 ms. Per byte, the whole registry load (hand-written parse, validation, cross-checks and
freeze) therefore takes about 30× longer than a native parse alone. The benchmark does not
split parse from validation. The 18.8 ms real-bundle
load is also paid on every save, twice (`StateCodec` content version and `SaveIO`
validation, §3.7).

## 3. Axis by axis

Each axis has three parts: what already supports it, what breaks first and why, and the
smallest structural change that removes the limit. Task ids refer to the accepted entries in
`docs/orca/BACKLOG.md` (Phase A).

### 3.1 1,000+ actors on screen-sized maps

**Already supports it.** A single tick pipeline (`WorldState.tick()`) with a fixed phase
order. A fair scheduler that evaluates at most `JOB_EVALUATION_BUDGET := 32` waiting entries
per worker (`scheduling/global_assignment.gd`, `tick()`), so it is not a full workers × jobs
product. Route searches are budgeted: each `resume()` runs at most `STEP_BUDGET := 64`
expansions (`routing/route_search.gd`), and the shared `_route_budget` ledger allows one call
per worker per tick (`global_assignment.gd` `tick()`, `toil_executor.gd`
`_resume_go_to_reroute()`). A per-tile region map gives O(1) reachability
(`map/regions.gd` `reachable()`), and the scheduler uses it to skip unreachable targets
before it starts a search.

**Breaks first, in measured order (§2.1):**

1. **A thirsty colony stops for minutes: need-source search is O(W·A²) per tick.** With
   water set to 20 on every colonist (§2.1, `needs`), the first tick takes 1.6 s at 10
   colonists, 9.6 s at 25, 38 s at 50 and 153 s at 100. That is ×4 per doubling, on a map
   with 2,218 water tiles of which 234 are reachable.
   - `NeedGiver._start_search()` runs once per colonist whose need crosses its threshold. It
     calls `WorldState._need_source_candidates("water")`, which hands every water tile to
     `_reachable_candidates_only()`.
   - `_reachable_candidates_only()` keeps a tile if `_colonists.any(...)` can reach it, so each
     unreachable tile is checked against every colonist. That is O(W·A) per searching colonist
     and O(W·A²) when they all start together.
   - Then `_start_search()` filters by `_claimed_targets` (a `get_jobs()` deep copy) and by a
     `"tile:%d,%d"` key per candidate, and sorts all candidates with a lambda.
   - Synchronised onsets are the normal case, not a contrived one. Every spawned colonist
     starts with the same needs (`ActorTable._spawn_colonist()` →
     `NeedsType.build_full_needs()`) and decays at the same rate (`_decay_needs()`).
   - After the onset, the searches cost 7.8 ms per tick at 10 colonists and 45 ms at 50,
     because each search resumes once per tick. No colonist reached water within 30 ticks.
     In a 120-tick run (`bench_tick_scaling.gd -- --workloads=needs --actors=10 --ticks=120`,
     not in the results file), 2 of 10 had.
   - Food does not show this on a fresh map only because there are no ground berries yet, so
     its candidate list is empty and the search fails at once. The first berries put food on
     the same path.
   - The fix is A4's: candidates per region, computed once per tick per need kind, not once
     per colonist against every colonist.
2. **No spatial index: combat is O(A²) even when nobody fights.** At 1,000 idle colonists,
   the `combat` phase is 1,788 ms of a 1,879 ms tick (95%).
   - `combat/combat_targeting.gd` `nearest_adjacent_hostile()` rebuilds a position Dictionary
     of every actor, with String keys, on every call. `CombatResolver.resolve_tick()` calls it
     once per actor, and `ApproachGiver.advance()` calls it again.
   - The same pattern recurs elsewhere: `WorldState._is_cell_occupied()`, `_colonist_at()`,
     `_find_colonist()`, `ItemTable.has_item_at()` and `ItemTable.get_ground_wood()` are all
     linear scans.
   - `WorldState._find_colonist()` is reached through `_actor_faction()` from
     `Passability.passable_for_worker()`, the route cost for autonomous actors. That makes every route-cost call for an incident
     actor O(A).
   - `_rescue_candidates()` checks components per actor on every tick: `rescue_giver` costs
     96 ms per tick at 1,000 idle colonists.
3. **Scheduler and route search, once colonists have work.** With one order per colonist,
   the `scheduler` phase is 333 ms at 500 colonists and 2,186 ms at 1,000. On the first tick
   at 1,000 it is 4,032 ms.
   - `GlobalAssignment.tick()` starts with `colonists.duplicate(true)` and a lambda sort,
     copies all jobs (`queue.get_jobs()`), and sorts up to 32·A proposals.
   - Each activation runs a route search. `RouteSearch` is plain Dijkstra:
     `_pop_min_index()` scans the whole frontier on every step, and `_ordered_neighbors()`
     allocates a 4-element array and sorts it with a lambda on every expansion. There is no
     heuristic, so expansions grow with the square of the distance (§2.3).
   - At the 64-step budget, a route across the 256×256 map needs 242 ticks before the
     colonist moves. At the base speed of 2 ticks per second
     (`viewer/tick_driver.gd` `BASE_TICKS_PER_SECOND := 2.0`), that is about two minutes.
4. **Per-colonist work is O(A·J) and copies.** `advance_colonists` is 668 ms per tick at 500
   busy colonists. At 10 colonists with 100 open orders it averages 36 ms, with single ticks
   of 1.3 s (§2.2).
   - `_advance_colonists()` copies and sorts the roster, then calls
     `_scheduler.queue.get_job()` per colonist, which is a linear `_find_job()` plus a deep
     copy.
   - Toil re-routes resume a search per colonist per tick, and
     `toil_executor.gd` `_resume_go_to_reroute()` stores a full `search.snapshot()`
     (frontier, visited, came_from) each time.
   - Every completed work job that changes a tile kind calls
     `_tile_grid.get_rooms().on_passability_changed()` (`_toil_on_work_complete()`). That call re-floods
     the whole surrounding area even when passability did not change (`rooms.gd`
     `_rebuild_area()`): 98 ms on the open generated map. The first call also builds rooms
     for the whole map (902 ms). These are the 1.3–1.6 s single-tick spikes.
5. **Map queries allocate.**
   - `Passability.passability()` (`map/passability.gd`; `WorldState.passability()` delegates
     to it) builds and returns a new Dictionary on every call, and `ObjectTable.get_object()`
     builds a `"%d_%d"` String key on every call (`object_key()`).
   - Every route expansion goes through this four times, once per neighbour, via
     `Passability.is_passable()` or `WorldState._routable_to()`. So does every region and room flood: about 8 µs per
     expansion on the real map.
   - Tick 1 of every world pays a lazy full-map region build through this path
     (`TileGrid.get_regions()`): 280–450 ms, in whichever phase asks first.
6. **Whole collections are deep-copied inside the core, every tick.**
   - `JobQueue.get_jobs()` is `_jobs.duplicate(true)`. It is called per tick by
     `HaulGiver.advance()`, `ConstructionGiver.advance()`,
     `WorldState._active_site_fetch_job_ids()`,
     `_resolve_freshly_activated_site_fetch_sources()` and the scheduler. `WorldState.get_jobs()`
     also runs `ToolHandover.apply()` over every job.
   - `WorldState.get_colonists()` deep-copies every actor. It is injected into `ToilExecutor`
     and `CalendarAlertGiver`, and the tool toils call it to look up one colonist
     (`jobs/tool_drop_toil.gd` `_colonist_busy()`).
   - This is why tick time follows the open backlog: 10 colonists with 2,000 open orders take
     235 ms per tick, 174 ms of it in the scheduler (§2.2).
7. **Unbounded searches outside the budget (found by reading, not measured).**
   `WorldState._route_cost()` runs a search to completion
   (`while not route.is_terminal(): route.resume()`). It is called for every candidate item
   in `_next_site_fetch_source()` and for every sibling site in
   `_reachable_short_sibling_sites()`. With many loose wood items, one construction decision
   can cost several full-map searches in one tick. Separately,
   `NeedGiver._advance_candidate_search()` resumes each searching colonist once per tick
   without consulting the shared ledger.
**Smallest structural change.** None of these needs a new architecture. They need data
structures under the existing APIs:

- a per-tile cost and object index, kept current at the existing `_mark_dirty()` choke point
  (A2, after R3 creates `map/passability.gd` and `map/tile_grid.gd`);
- a heap-based search with no per-step allocation (A3, identical results);
- need-source candidates computed once per tick per need kind and per region, and a per-tile
  occupancy index owned by `ActorTable`/`ItemTable` (A4);
- read-only views in place of deep copies inside the core, and an id → job index (A5);
- A* and a region-aware abstraction later (A8; this changes which of several equal paths is
  chosen, so it needs an ADR).

The tick loop, the job engine and the contracts stay as they are.

### 3.2 Long sessions (a limit the ambition implies)

**Breaks first.** Several structures only ever grow:

- `JobQueue._jobs` keeps every terminal job. The only writes are `append` in `submit` and
  the whole-array replacement in `restore`.
- `JobQueue._events` is never trimmed, and `_emit()` re-sorts the whole list
  (`_events.sort_custom(_event_before)`) on every event.
- `EventLog._events` is never trimmed. `insert_event()` is an insertion into an ever-growing
  array, and `get_events()` deep-copies all of it for the viewer
  (`viewer/status_text.gd`, `viewer/work_table_panel.gd`).
- `TileGrid.dirty_cells` is append-only by contract, and `get_dirty_cells()` copies the
  whole log on every viewer refresh (`viewer/map_view.gd` `_refresh_tile_map()`).

§2.2 shows the effect at 10 colonists: tick time grows with the number of jobs ever created.
The cost is paid by every colony that plays long enough, whatever its size.

**Smallest change.** Retire terminal jobs into a bounded history and index live jobs by id
(A5; a save-format change, so it needs a schema bump and migration). Turn the event and
dirty-cell logs into cursor-based streams with bounded retention (A6; events are not
persisted, so there is no save change).

### 3.3 Several map layers (underground)

**Already supports it.** `world_generator.gd` is a pure module, and regions and rooms are
separate modules with their own index math. R3 gave the map a single owner
(`map/tile_grid.gd`).

**Breaks first.** The whole core is 2D by construction:

- one `TileGrid.tiles: Array[String]` with `tile_index(x, y) = y * width + x`
  (`map/tile_grid.gd`); `regions.gd`, `rooms.gd` and `world_generator.gd` each repeat that
  index math;
- 506 `Vector2i` occurrences in `game/scripts/core` (138 in `world_state.gd`);
- at least four incompatible String key formats for a tile: `"%d_%d"` (`ObjectTable.object_key()`,
  `ItemTable`, `combat_targeting.gd`), `"tile:%d,%d"` (`_tile_key()`), `"cell:%d,%d"` (`_cell_key()`) and
  prefix + `"%d,%d"` (`job_queue.gd` `_target_key()`);
- saves encode coordinates as `{x, y}` (`state_codec.gd` `_encode_tile()`).

`foundation-for-breadth.md` already lists z-levels as deferred.

**Smallest change.** Decide the coordinate model before F4, in an ADR (A12). The choice is
between a layer index carried next to `Vector2i` everywhere, `Vector3i`, or one flat tile
index across layers with per-layer offsets. Then route every key through one helper so that
adding a layer is one change, not 506. R3's `TileGrid` is the natural owner. Doing A2
(integer tile indices for objects and costs) first removes most of the String keys.

### 3.4 Hundreds of content kinds

**Already supports it.** `ContentRegistry` (ADR 010) discovers every `content/*.json` that has
a schema, validates it, cross-checks references and freezes it. Actors are definitions plus
components (ADR 012). `extension-points.md` documents the recipes. Load time grows linearly
and is acceptable: about 90 µs per added entry, so +1,000 items and +1,000 objects load in
about 0.2 s (§2.5).

**Breaks first: kinds are content, but behaviours are still code.**

- `WorldState._toil_on_work_complete()` has a `match job["kind"]` with one arm per work kind
  (dig, chop, mine, forage, till, sow, site_work), each hard-coding its tile change and its
  yield (`spawn_item("sand")`, `spawn_wood_item()`, `spawn_stone_item()`). A new work kind is
  a code change in the largest file.
- Needs match on `food`/`water`/`rest` with `"bed"` (`_need_source_candidates()`).
  `ItemTable` has dedicated `spawn_wood_item`/`spawn_stone_item`/`spawn_berries_item`.
  Berries are a separate `ground_berries` map, not an item.
- The save validator repeats content as code: tile and job whitelists and need keys in
  `save_io.gd` `_validate_state()`, and `ENTITY_COMPONENT_FIELDS` keyed by colonist, wolf and
  trader. `LABOUR_KINDS` exists both in `world_state.gd` and `save_io.gd`.
- `lint_content_literals.ps1` only catches three const patterns, so bare literals in `match`
  arms pass. Counts in core today: `"site_fetch"` 28, `"haul"` 19, `"dig"` 14, `"chop"` 10.
- The registry's JSON-Schema subset has no `enum`, `oneOf`, `$ref` or `pattern`
  (`_validate_node()`), and `_freeze_collection()` silently overwrites a duplicate id.
- The registry uses a hand-written GDScript JSON parser (`_parse_json()`, needed to keep ints
  as ints). Together with validation, a load takes about 30× longer per byte than a native parse
  (§2.5). That is harmless at today's 13 KB, but it is the main cost for a large bundle.

**Smallest change.** Data-driven work effects: `jobs.json` gains an `effects` block (tile
transform, yields), and `_toil_on_work_complete()` applies it generically (A14, after R11
moves the toil callbacks). Duplicate-id detection and `enum` support in the registry (A13).
Save validation reads its whitelists from the registry (A7 or A13).

### 3.5 Scripted stories, events and quests

**Already supports it.** Incidents are content (`incidents.json`, five entries) fired by
`IncidentScheduler` with a daily budget (`DAILY_BUDGET_POINTS := 3`), `min_day` and
`cooldown_days`. Commands in, events out, a calendar service, and a seeded RNG.

**Breaks first.** There is no condition, trigger, flag, chain, choice or quest state
anywhere. The incident schema forbids extra fields. Spawn edges are a hard-coded `match`
(`incident_scheduler.gd` `_spawn_tile()`), and the daily draw has no random roll
(`_run_daily_draw()`). A story beat today would be new code in `WorldState`.

**Smallest change.** A design first (A17, ADR only): rules of the form trigger → condition
→ effect, evaluated by one "story giver" in the job-giver pattern (ADR 011), whose effects
are ordinary commands and whose state (flags, quest stages) is persisted like any other
module. Incidents become one kind of effect. This fits the existing extension points; it does
not need a new engine.

### 3.6 Multiple scenarios and levels

**Breaks first.** There is no scenario format. A new game is `WorldState.new(seed, rate,
width, height)` plus generator constants. The only alternative start is code:
`viewer/debug_scenario.gd`, which also writes `world._items` and `world._next_item_id`
directly. Map size, roster size (`mapgen.json` `colonist_count`), starting items and the
enabled incidents are not grouped into anything a level designer could edit.

**Smallest change.** A `scenarios.json` content kind with a schema (map size, seed or fixed
map, starting roster, items and objects, enabled incidents, calendar), and a new-game path
that builds a world from one scenario entry. `debug_scenario.gd` becomes the first entry
(A16).

### 3.7 Localisation and mods or data packs

**Localisation.** The viewer already has a key-based `TextTable` (`viewer/text_table.gd`
over `data/text/en.json`, 134 keys), which is the right start. But:

- there is no locale switch or fallback, and no `tr()` or `TranslationServer` anywhere;
- the core returns English `message` strings next to its stable reason codes (about 28 sites,
  for example `commands/command_checks.gd` `check_target_job_command()`);
- viewer files still hold English literals (`colonist_panel.gd`, `control_bar.gd`,
  `new_game_dialog.gd`, `status_text.gd`, `boot.gd`);
- content embeds English labels (`tiles.json` `display.label`, `calendar.json` `label`).

The fix is mechanical (A15): the core returns codes and parameters only, every visible
string is a key, and `TextTable` gains a locale with an `en` fallback.

**Mods and data packs.** `ContentRegistry` reads one directory pair
(`DEFAULT_CONTENT_DIR := "res://content/"`), discovers files non-recursively
(`_discover_content_kinds()`), and has no load order, overlay or merge rule. It is also
rebuilt from disk at six call sites instead of being built once per session: `WorldState`
`_init()`, `StateCodec` (content version on every save), `SaveIO._validate_state()` (map
size on every validation), `save_migrations.gd`, `boot.gd` and `viewer/new_game_setup.gd`. `CalendarService` can read
`res://content/calendar.json` itself, bypassing the registry (`save_migrations.gd` calls
`CalendarServiceType.new()` with no document). A pack system needs one registry instance per
session, built from an ordered list of roots with explicit append and override rules,
duplicate-id errors, and a pack id recorded in saves (A13).

### 3.8 Mobile target

**Already supports it.** ADR 003 sets mobile-first rules. The renderer is `gl_compatibility`
(`project.godot`), the simulation is headless-testable, and autosave runs on backgrounding
(`viewer/autosave_trigger.gd`).

**Breaks first.**

- `export_presets.cfg` has a single `Web` preset, with no Android or iOS preset.
- There is no touch input (no `InputEventScreenTouch` or `InputEventScreenDrag`), and no
  stretch mode is set in `project.godot`. ADR 018 says validation is temporarily PC-only.
- The simulation runs on the main thread, inside `TickDriver._process()`, with no cap on
  catch-up ticks per frame (`while _accumulator >= 1.0: world.tick()`). A slow tick
  therefore becomes both a frame hitch and more ticks owed on the next frame.
- A save blocks the main thread for the whole encode, validate, stringify, hash, write and
  read-back (`SaveIO.write_atomic()`, §2.4), and autosave runs every 600 ticks
  (`SaveConfig.AUTOSAVE_INTERVAL_TICKS`).
- Nothing has been measured on a phone. The numbers in §2 come from one of the fastest
  desktop CPUs available, and a mid-range phone runs GDScript several times slower.

**Smallest change.** A measured spike (A18): an Android preset, a stretch mode, touch pan and
zoom, and `bench_tick_scaling.gd` run on a reference device to get the real device factor.
An ADR then decides whether the tick moves to a worker thread with a snapshot handed to the
viewer. The core already has the shape for that (commands in, snapshots and events out); the
viewer's direct field reads (§4.3) are what would break.

## 4. Cross-cutting findings

### 4.1 Allocation and copy patterns in hot paths

| Pattern | Where | Fix |
| --- | --- | --- |
| New Dictionary per passability query | `Passability.passability()` | A2: integer cost array, Dictionary only at the public API |
| String key per object or tile lookup | `ObjectTable.object_key()`, `_tile_key()`, `_cell_key()`, `ItemTable` berries, `combat_targeting.gd` | A2/A4: integer tile index |
| Deep copy of all jobs inside the core | `JobQueue.get_jobs()` callers listed in §3.1 | A5: read-only view |
| Deep copy of all actors | `GlobalAssignment.tick()`, `get_colonists()` from toils and givers | A5: read-only view, id index |
| Sort per call | `ContentRegistry.list()`, `ItemTable.get_items()`, `_advance_colonists()`, `JobQueue._emit()` | sort once, or keep sorted |
| Array allocation and lambda sort per expansion | `RouteSearch._ordered_neighbors()` | A3: constant neighbour order (already row-major) |
| Search snapshot per tick while rerouting | `toil_executor.gd` `_begin_go_to_reroute()`/`_resume_go_to_reroute()` store `search.snapshot()` (frontier, visited, came_from) on every call | A3/A7: snapshot only at save time |
| O(objects) backfill every tick | `ObjectTable.ensure_object_health()` (from `WorldState._decay_needs()`), plus `_ensure_needs()`/`_ensure_health()`/`_ensure_combat()` over all actors | run at load and spawn only |

### 4.2 Memory: worlds are never freed

`bench_save_load.gd`'s leak check builds and drops `WorldState`s and counts live Objects
(§2.4). `WorldState` hands bound `Callable`s of itself to every module it builds (for example
`ItemTable.new(..., passability, get_tile, ...)` and `ToilExecutor.new(...)` in `_init()`),
and the modules are fields of the world, so each world sits in a reference cycle that
`RefCounted` cannot collect. Each load or new game in a session leaks the previous world.
The fix is an explicit `dispose()` that clears the module fields, called by whoever replaces
the world (viewer save wiring), plus a test that the object count returns to its baseline
(part of A7).

### 4.3 The simulation/presentation boundary has holes

`test_architecture_rules.gd` `_check_viewer_purity()` only inspects method calls
(`world.X(` must be `get_*`, `apply`, `tick` or `get_events`), so field access passes:

- `viewer/control_bar.gd` reads `world._content.list("incidents")`;
- `viewer/order_input.gd` reads `world._content.list("objects")`;
- `viewer/debug_scenario.gd` iterates `world._colonists` and writes `world._next_item_id`
  and `world._items[...]`, which is a direct mutation of simulation state.

The viewer also pulls deep copies every tick (`get_colonists()`, `get_jobs()`, `get_items()`,
`get_objects()`), rebuilds one Label/Button row per colonist on every tick
(`viewer/colonist_panel.gd` `refresh()`), scans all jobs once per colonist
(`viewer/colonist_sprites.gd` `_is_building()`), and draws each actor as an
`AnimatedSprite2D` plus up to five more nodes (`colonist_sprites.gd` `_refresh()`, health
bars). At 1,000 actors that is about 4,000 to 6,000 CanvasItems, rebuilt from copies on every
tick. A9 covers this: a read-only snapshot per tick, batched actor drawing (one
`MultiMeshInstance2D` or one `_draw()` per layer), incremental panels, and a purity rule
that also rejects `world._field` access.

### 4.4 Save pipeline

What is solid: an atomic write with read-back verification, a SHA-256 integrity hash, 24
sequential migrations with fixtures (schema 25, `state_codec.gd` `SCHEMA_VERSION`), typed
error codes, and rotating autosave slots. That is better than most shipped games.

What does not scale (numbers in §2.4):

- **One JSON document**, with tiles as an array of 65,536 strings (`state_codec.gd`
  `encode()`, `"tiles": world._tiles.duplicate()`).
- **In-flight route searches saved in full.** `StateCodec._encode_route()` writes
  `visited`, `cameFrom` and `frontier`. One long search is up to about 2 MB of JSON (§2.3,
  `snapshot_json`).
- **`write_atomic()` does the work several times.** It runs `_validate_state()`, which
  rebuilds a `ContentRegistry` from disk; deep-copies the state; stringifies it three times
  and parses it once; then reads the file back, parses it and hashes it again. All of this
  happens on the main thread.

The smallest change (A7): one registry per session, one stringify and one hash, a compact
tile encoding (palette plus run-length; a schema bump with a migration and fixture), route
state saved as `{start, target, expansions}` and replayed deterministically on load, and the
file write and read-back moved off the main thread after `encode()`.

## 5. Best-practice check

### 5.1 Simulation architecture for this genre

| Practice | Status | Evidence / gap |
| --- | --- | --- |
| Fixed-step, deterministic simulation | **Strong** | `tick()` is the only time source (`SeededClock`), and RNG streams are seeded and salted (`GEOGRAPHY_SEED_SALT`, `DIG_FIND_SEED_SALT`, ...). `test_world_state_determinism.gd` replays to equal `state_hash()`. |
| Commands in, events out | **Strong** | `apply()`/`preview()`, `command_checks.gd` as the single pre-mutation check, typed reason codes. |
| Data-oriented storage | **Weak** | Entities, jobs and items are nested `Dictionary`s with String keys (1,725 `Dictionary` occurrences in core). Fine for hundreds of entities; at thousands, packed per-component arrays (or at least typed `RefCounted` records) beat it on both speed and memory. Not a first step: A2–A5 remove most of the cost without changing the data model. |
| Event or message bus vs. direct calls | **Mixed** | Events exist (two logs) but are output-only. Modules talk through dozens of injected `Callable`s (`ToilExecutor.new()` takes about 35 parameters). That is explicit and testable, but every new system adds parameters, and the callables create the leak in §4.2. A small typed "services" record per module would keep the explicitness with fewer parameters. |
| Spatial indexing | **Missing** | Only regions (per-tile ids). There is no occupancy, item or nearest-X index (§3.1). |
| Object pooling | **N/A in GDScript, alloc avoidance instead** | GDScript has no pooling story worth having for Dictionaries. The win is not allocating at all in hot paths (§4.1). |
| Content hot-reload | **Missing** | No reload path. The registry is frozen per instance, which is the right base for one: rebuild, diff, apply at a tick boundary. Not a priority before packs (A13). |
| Versioned schemas | **Strong** | Save schema 25 with 24 migrations and fixtures; `contentVersion` from the manifest, with a rename hook. Gap: content schemas are not versioned per file, and construction sites entered without a bump (`save_io.gd` comment at the `sites` validation). |
| Replay and debug tooling | **Missing** | No command recording or playback. Determinism is tested but not tooled. A11 records the command stream and replays it headless, checking `state_hash()` checkpoints, so a desync becomes a failing tick number instead of a bug report. |
| Headless test coverage | **Strong** | 90 headless tests including architecture rules, save migration, determinism and viewer purity. Gap: no performance regression signal. These benchmarks are a baseline, and A1 makes them a routine report (not a gate). |

### 5.2 Godot 4

| Practice | Status | Evidence / gap |
| --- | --- | --- |
| Thin scenes, code-built UI | **OK** | One scene (`scenes/boot.tscn`, a single `Node`), no autoloads, UI built in code. Simple and diff-friendly; editor tooling for designers will need real scenes later. |
| Rendering at scale | **Weak** | Node-per-actor sprites, full-map `draw_rect` in colour mode (`map_view.gd` `_draw()`), overlays redrawn per refresh. `TileMapLayer` updates are incremental, which is good. See §4.3. |
| GDScript performance | **Weak in hot paths** | Callable indirection per tile, String formatting for keys, `duplicate(true)` in loops (§4.1). Typed `Packed*Array`s and integer keys are the standard GDScript fixes. |
| Static typing | **Mostly typed, not enforced** | In core: 1,247 inferred (`:=`) and 1,220 explicit typed declarations, against 102 untyped `var x =` and 61 of 1,071 functions without a return type. `project.godot` has no `[debug]` GDScript warning settings, so nothing stops new untyped code. A10 enables `untyped_declaration` and `unsafe_*` warnings for core and fails CI on new ones. |
| Threads | **None** | Fine for determinism today. Moving the tick to a `WorkerThreadPool` task needs the viewer to read snapshots only (§3.8, A9). |
| Export and mobile | **Web only** | §3.8, A18. |

## 6. What is solid and should be kept

- The **core/viewer split** and its rules (`AGENTS.md`, `simulation-boundaries.md`), enforced
  by tests, apart from the field-access gap in §4.3.
- **Determinism**: one tick path, seeded and salted RNG streams, stable event ordering, and
  `state_hash()` replay tests.
- **One work engine** (ADR 011): jobs made of toils, one queue, one scheduler with a written
  fairness policy (ADR 004), givers for decisions. This is the right shape for thousands of
  behaviours; its data structures are what is slow, not its design.
- **Content registry plus components** (ADR 010, ADR 012): definitions are data, validated
  at startup.
- **Save system**: atomic, verified, versioned, migrated, with fixtures.
- **Process**: contracts before code, ADRs, core size budgets, headless tests as the gate,
  and Phase R breaking up `world_state.gd`.

## 7. Order of work and relation to Phase R

Phase R stays first: it gives each subsystem one owner file, and most A-tasks land inside
those owners. A-tasks that touch `world_state.gd` are scheduled between R steps, never in
parallel with one, because every R step edits that file. The order is:

1. **A1** (benchmark runner and baseline) can go at any time. It touches `tools/` and docs
   only.
2. **A2 → A3 → A4 → A5 → A6** are the performance foundation: map queries, route search,
   spatial index, job storage, bounded streams. A2's prerequisite, R3, is done. A3 is
   self-contained. A4's combat part waits for R9. A5 is best after R4/R5. A6 is self-contained.
3. **A7** (save pipeline) after A5, since both change the save format; the two can share one
   schema bump.
4. **A8** (A* and region-aware routing) after A3, with an ADR, because paths may change.
5. **A9** (viewer at scale) after A5, since it needs the read-only snapshot.
6. **A10, A11** (typing gate, replay tool) are cheap and can go at any time. A11 is worth
   having before A8.
7. **A12–A17** are the breadth foundations: layers ADR, content packs, data-driven job
   effects, localisation, scenarios, story layer. Their ADRs can be written in parallel;
   their code waits for R12.
8. **A18** (mobile spike) before any mobile commitment; it calibrates every number here.

How this relates to entries `main` added while this audit ran:

- **B1** (large area orders freeze the game). §2.2's backlog sweep is the tick side of that
  symptom: 2,000 open orders make 10 colonists tick at 235 ms, and room re-floods add
  single ticks of 1.3–1.6 s. B1's own `bench_area_orders.gd` covers preview and apply. A2's
  rooms fix and A5's job index remove the tick-side causes, so B1 should not reimplement
  them; it can cite these numbers as its "before".
- **R14** (reset the save schema to v1 after R12). R14 is a one-time reset, not permission
  for later unversioned changes. A5 and A7 change the save format, so each ships with a
  schema bump, a migration from the previous version and a fixture, whenever it lands. After
  R14 that is a v1 → v2 bump. Before R14, it is one more step in today's chain, which R14
  will then delete. Landing them after R14 avoids writing a migration that R14 throws away;
  it does not remove the need for one.
- **R15** (tests stop reaching into private fields). The benchmarks reach into private
  fields too: `bench_common.gd` `profiled_tick()` and the sizes printed by
  `bench_long_session.gd`. R15 should give them the same test surface.

## 8. Limitations of this audit

- Benchmarks seat cloned colonists around one clearing and order tilling (no tool needed),
  so they exercise movement, scheduling, needs and combat bookkeeping but not construction,
  hauling or real combat. Construction's unbounded searches (§3.1, item 7) are found by
  reading the code, not measured.
- Timings are single runs on one host. The tick benchmark reports p50/p95 over up to 30
  ticks, and other numbers are single samples. Expect up to ±25% run to run, so compare orders
  of magnitude, not decimals.
- `profiled_tick()` reaches into private `WorldState` fields and methods. If `tick()` changes,
  the copy must follow it. When it does not, `hash_match=false` is printed and the benchmark
  exits 1.
