# Backlog

> **In short:** The ordered list of work. An agent takes exactly one entry, by its id, in
> the order given, and does nothing outside it. `R*` entries are the refactor
> (`REFACTOR-PLAN.md`), strictly sequential. `F*` entries are game features towards the
> baseline (`../design/baseline.md`); each one is opened only after its design questions
> are answered by the owner and written here.

Status is kept in this file: `todo` → `doing (branch)` → `review` → `done (PR #)`. The
agent that finishes a task updates its own row in the same PR.

## How to read an entry

- **Goal** — what is true when the task is done.
- **Owned paths** — the only files the task may change (plus their tests and docs).
- **Acceptance** — checks a reviewer can run. All of them must pass.
- **Non-goals** — what is explicitly out, even if tempting.

Every task also inherits: import first, full headless suite green on Windows, handoff report
as `docs/orca/handoffs/<id>.md` per `AGENTS.md` (the reviewer only sees the repo), no
behaviour change in `R*` tasks.

---

## Phase R — composed core (sequential, except entries marked *parallel-safe*)

### R0 — Tooling for the Orca workflow · `done` (this PR)

Windows test runner (`tools/run_tests.ps1`), `tools/measure_core.ps1`, `GODOT` env var,
Orca helper scripts, this backlog.

### R0b — Stop `godot --import` from dirtying the worktree · `done (PR #3)` · *parallel-safe*

- **Goal:** after `godot --headless --path game --import` on a fresh checkout, `git status` is
  clean. Today 31 `game/assets/generated/**/*.png.import` files come back modified by line
  endings only (committed with CRLF, rewritten with LF, or the reverse). Normalise them once and
  pin the rule in `.gitattributes` so it cannot drift again.
- **Owned paths:** `.gitattributes`, `game/**/*.import`, `game/README.md` (one line).
- **Acceptance:** on a fresh worktree, run the import twice and `git status --porcelain` prints
  nothing; `git diff --stat main` shows only line-ending changes (`git diff -w --stat` empty);
  CI import + boot steps still pass.
- **Non-goals:** touching `.tres`, `.uid`, scripts or any content.

### R1 — Extract `EventLog` · `done (PR #1)`

- **Goal:** `game/scripts/core/world/event_log.gd` owns `_events`, `_event_sequence`,
  `_queue_event_sequence`, event insertion/ordering (`_insert_event`, `_next_sequence`,
  `_event_less`), `_collect_queue_events`, and the applied/rejection envelope helpers
  (`_applied`, `_rejection`, `_pure_rejection`, `_reject`, `_apply_noop`). `WorldState`
  delegates; `get_events()` keeps its signature and output.
- **Owned paths:** `game/scripts/core/world_state.gd`, `game/scripts/core/world/event_log.gd`
  (new), `game/scripts/core/persistence/state_codec.gd` (encode/decode of events and
  sequences via the module), `docs/architecture/core-budgets.json`, tests that read
  `_events`/`_event_sequence` directly.
- **Acceptance:** full suite PASS; `test_save_migration` fixtures unchanged; a saved game's
  JSON before/after is byte-identical for the same scenario (show the diff command in the
  report); `world_state.gd` cap lowered to its new size; `tools/measure_core.ps1` numbers in
  the report.
- **Non-goals:** changing event names, order or payloads; touching the viewer.

### R2 — Extract `ItemTable` · `done (PR #4)`

- **Goal:** `game/scripts/core/items/item_table.gd` owns ground items, ground berries, item
  factions, `_next_item_id`, and every spawn/place/remove/consume/lookup function listed in
  `REFACTOR-PLAN.md` R2, plus the dig-find roll (`_roll_dig_find`, `_resolve_dig_finds`,
  `_dig_item_placement`) with its own injected seeded RNG (`_dig_find_random`). Tool items
  (`tool_item_store.gd`) move under `items/` unchanged.
- **Owned paths:** `world_state.gd`, `items/` (new), `state_codec.gd`, `core-budgets.json`,
  the givers/toils that call the moved functions (delegation only), affected tests.
- **Acceptance:** as R1, plus: `state_hash()` still covers item factions exactly as before
  (deliberately excluded) and `_object_health` exactly as before (included); dig-find
  sequence identical for the same seed (`test_dig_finds` or the equivalent existing test).
- **Non-goals:** item stacking rules, new item kinds.

### R3 — Extract `TileGrid`, `ObjectTable`, `ZoneTable`, `Passability` · `done (PR #5)`

- **Goal:** four modules under `map/` and `objects/` own tiles + water cache + dirty cells,
  placed objects + footprints + origin/orientation/health/factions, zones, and the
  passability/faction rules. `regions.gd`/`rooms.gd` are owned by `TileGrid` (lazy build
  preserved). `WorldState` delegates.
- **Owned paths:** `world_state.gd`, `map/tile_grid.gd`, `map/passability.gd`,
  `objects/object_table.gd`, `objects/zone_table.gd` (new), `state_codec.gd`,
  `core-budgets.json`, callers (delegation only), affected tests, viewer files only if they
  called a moved private function (replace with the public getter).
- **Acceptance:** as R1; `get_dirty_cells()` semantics unchanged (append-only); regions and
  rooms rebuilt lazily exactly as before (the existing region/room tests prove it).
- **Non-goals:** multi-layer maps (that is F-phase).

### R4 — Extract `WorkProgress` · `review (antonelmejor50-hub/r4-extract-workprogress)`

- **Goal:** `jobs/work_progress.gd` owns `_work_progress`, `_work_progress_owner`,
  `_suspended_work_progress` and every function that reads or writes them, including the
  load-time owner reconstruction. Persisted field names unchanged
  (`workProgress`, `workProgressOwners`, `suspendedWorkProgress`).
- **Owned paths:** `world_state.gd`, `jobs/work_progress.gd` (new), `state_codec.gd`,
  `core-budgets.json`, affected tests.
- **Acceptance:** as R1; `test_save_migration` and the suspend/resume tests unchanged.

### R5 — Extract `ConstructionSystem` · `review (antonelmejor50-hub/r5-extract-constructionsystem)`

- **Goal:** `objects/construction_system.gd` owns sites and the whole construction flow
  (submission, footprint/terrain checks, site fetch source selection, site work, finalize,
  cancel, enclosure check, build-line batching). `construction_giver.gd` talks to it, not to
  `WorldState`.
- **Owned paths:** `world_state.gd`, `objects/construction_system.gd` (new),
  `objects/construction_site.gd`, `jobs/givers/construction_giver.gd`, `state_codec.gd`,
  `core-budgets.json`, affected tests.
- **Acceptance:** as R1; `test_build`, `test_wall_orders`, the site-fetch tests unchanged.

### R6 — Extract `TrenchSystem` · `review (antonelmejor50-hub/r6-extract-trenchsystem)`

- **Goal:** `actors/trench_system.gd` owns trapping, climb-out, escape job submission,
  rescue candidate/victim pools and rescue reasons; `rescue_giver.gd` depends on it.
- **Owned paths:** `world_state.gd`, `actors/trench_system.gd` (new),
  `jobs/givers/rescue_giver.gd`, `state_codec.gd`, `core-budgets.json`, affected tests.
- **Acceptance:** as R1; `test_trapped_actors`, `test_rescue` unchanged.

### R7 — Extract `TradeSystem` · `review (antonelmejor50-hub/r7-extract-tradesystem)`

- **Goal:** `economy/trade_system.gd` owns pending offers and `accept_trade`.
- **Acceptance:** as R1; trader tests unchanged.

### R8 — Extract `NeedsSystem` · `todo`

- **Goal:** `actors/needs_system.gd` owns decay, interrupt/suspend/resume of the current
  job for needs, need reasons/events, source candidates and need effects;
  `need_giver.gd` depends on it.
- **Acceptance:** as R1; `test_need_jobs`, `test_needs_*` unchanged.

### R9 — Extract `CombatSystem` · `todo`

- **Goal:** `actors/combat_system.gd` owns `_apply_combat`, combat reasons, death and its
  cleanup (scheduling, inventory drop). `combat_giver.gd`/`approach_giver.gd` depend on it.
- **Acceptance:** as R1; `test_combat`, `test_incidents` unchanged.

### R10 — `CommandRouter` and command handlers · `todo`

- **Goal:** `world/command_router.gd` validates, dispatches to one handler per command
  family under `commands/handlers/`, and builds the applied/rejected envelope through
  `EventLog`. `apply()` and `preview()` in `WorldState` become three lines each.
  `command_checks.gd` stays the single place for pre-mutation checks.
- **Acceptance:** as R1; every rejection reason string unchanged (grep the tests).

### R11 — `ToilBindings` · `todo`

- **Goal:** `jobs/toil_bindings.gd` owns every `_toil_*` callback and the carried-item
  drop/deposit helpers, and wires them into `ToilExecutor` the way `_toil_hooks` does today.
- **Acceptance:** as R1; `test_tool_items`, haul and site-fetch tests unchanged.

### R12 — `TickPipeline` and façade cleanup · `todo`

- **Goal:** `world/tick_pipeline.gd` lists the per-tick phases in order (needs → givers →
  scheduler → toils → combat → incidents → calendar → caches); `WorldState.tick()` runs it.
  Dead code removed; `world_state.gd` under 900 lines; `core-budgets.json` replaced by the
  flat rule (800 lines per core file, 80 per function) and the CI step updated; one ADR
  "composed core" supersedes the budget-increase ADRs.
- **Acceptance:** suite PASS; `tools/measure_core.ps1` shows no core file above 800.

### R13 — Split `boot.gd` · `done (PR #2)` · *parallel-safe (viewer only, no core files)*

- **Goal:** `game/scripts/boot.gd` becomes scene composition only; new-game setup, save
  wiring and input wiring move to `viewer/` modules. Under 300 lines.
- **Acceptance:** headless boot check passes; manual run shows the same screen and tools.

### R14 — Reset the save schema to v1 (after R12, before any public release) · `todo`

- **Why (owner, 2026-10-25):** 24 chained migrations and 14 frozen fixtures exist for saves
  nobody has; `save_io.gd` is 2,200 lines with a 300-line validator. Pure legacy weight.
- **Goal:** one schema, `deepholm-save-v1` = today's shape after R12 (whatever the composed
  core persists), with its JSON Schema regenerated; `save_migrations.gd` reduced to the empty
  chain plus the mechanism (kept, it will be needed after release); old fixtures deleted;
  `save_io.gd` validator split per module (each module validates what it persists) and under
  the 800-line cap; `save-system.md` rewritten to match.
- **Acceptance:** a save written on `main` before the task fails to load with a clear
  "unsupported pre-release save" message (tested); fresh save → load → identical
  `state_hash` (tested); full suite passes; `measure_core` shows no persistence file above
  800 lines.
- **Non-goals:** changing what is persisted.

### R15 — Test hygiene (after R12) · `todo`

- **Goal:** tests stop reaching into private fields: each module exposes the small read-only
  test surface it needs (`debug_*` getters or a `TestAccess` helper), tests use it; shared
  scenario builders deduplicated into `tests/support/`; the 3 largest test files split by
  subject; `tools/run_tests.ps1 -Filter` documented per subject in `game/README.md`.
- **Acceptance:** `git grep "_world\._\|world\._" game/scripts/tests` returns 0; assertion
  count unchanged (quote before/after); suite time not worse than before by more than 5 %.

### R16 — Comment and doc pass on the composed core (after R12) · `todo`

- **Goal:** every core file's comments are the *why* in ≤3 lines per function; invariants that
  were prose become `assert`s or tests; `docs/architecture/*.md` and the ADR index updated to
  the module names (R2 and R3 listed the stale references in their handoffs); duplicate ADR
  numbers renumbered with redirects noted in the index.
- **Acceptance:** `measure_core` comment lines in `game/scripts/core/` below 25 % of total;
  `git grep` finds no `_events`, `_items`, `_tiles`, `_objects` field names in docs; suite passes.

---

## Phase B — bugs found by the owner's playtests

### B1 — Large area orders freeze the game and the selection lags the cursor · `todo` · *parallel-safe (coordinate with R4 on world_state.gd)*

- **Symptom (owner, 2026-10-25, main `e0a9f56`, native Windows build 1600×900):** dragging a
  large rectangle for an order (dig/mine/chop/cancel/zone) makes the game stutter and then
  freeze ("no es capaz de procesar"); while dragging, the drawn selection trails behind the
  real cursor position.
- **Goal:** both symptoms gone. Dragging any rectangle up to the whole 256×256 map stays at
  frame rate with the preview glued to the cursor; releasing a whole-map order never blocks
  the frame for more than a few milliseconds; the resulting jobs/zones are the same as today.
- **Find the causes, with numbers, before fixing:** likely (a) the viewer recomputes the
  valid/invalid preview for every tile of the rectangle on every mouse move, through
  `WorldState.preview()` per tile; (b) `apply()` of an area order creates/validates thousands
  of jobs synchronously (job queue insertion, reservations, reachability by region) in one
  frame; (c) per-frame rebuild of designation overlays/TileMap cells instead of incremental
  updates. Write `game/scripts/tests/bench_area_orders.gd` (headless) measuring: preview of a
  rectangle of N tiles, apply of an area order of N tiles, for N = 100 / 1,000 / 10,000 /
  65,536; quote before/after numbers in the handoff.
- **Fix principles:** the core stays deterministic and tick-based — if an area order must be
  spread over several ticks, that is an explicit, deterministic, saved queue (a command that
  expands N tiles per tick), never wall-clock based; the viewer does only incremental work per
  frame (diff of the rectangle against the previous frame; coarse preview — e.g. one cheap
  check per tile without routing — with the exact check only on release); no per-frame
  allocations proportional to map size.
- **Owned paths:** `game/scripts/viewer/` (order tools, designation overlay, map view),
  `game/scripts/core/commands/` and `game/scripts/core/world_state.gd` ONLY in the area-order
  apply path (R4 is extracting `*_work_progress*` at the same time: do not touch those
  functions), `game/scripts/core/jobs/job_queue.gd` if insertion cost is the culprit, new
  bench + tests, `docs/architecture/orders-and-movement.md` if the order semantics change
  (then an ADR too).
- **Acceptance:** `bench_area_orders.gd` numbers in the report, before and after; the full
  suite passes; a new headless test proves a whole-map dig order yields the same job set as
  before (count, targets, order) and that a save taken mid-expansion (if expansion is spread
  over ticks) reloads and completes identically; the owner reproduces the drag on the native
  build and confirms no freeze and no lag.
- **Non-goals:** changing which tiles are valid for an order; new order kinds; UI redesign.
- **Scope extension approved by the owner (2026-10-25 13:40):** the measured root causes are
  quadratic structures in `core/jobs/job_queue.gd`, `core/world/event_log.gd`,
  `core/scheduling/global_assignment.gd` (+ `assignment_queue.gd`) and per-tick deep copies.
  B1 may change those files (complexity only, behaviour byte-identical), add job index/log
  modules under `core/jobs/`, and — only if a whole-map apply still blocks > ~100 ms after
  that — add a deterministic, persisted per-tick expansion queue for area orders (schema bump
  + migration + fixture + ADR). Work-progress functions stay R4's. Order of work and
  coordination notes: `docs/orca/handoffs/B1.md`.

---

### B2 — Colonists (and later everything) drawn with the Pixel Crawler pack, not placeholders · `review` (branch `antonelmejor50-hub/b2-colonists-and-later-everything`) · *parallel-safe (viewer + assets only)*

- **Owner (2026-10-25):** "el pixelart de los colonos no es muy bonito, se debería parecer más
  al pixelart del pack que descargamos". Visual target stays Dwarf Fortress-like flat top-down
  16 px tiles (`docs/art/style.md`); colonists 24 px tall as decided earlier.
- **Size revised (owner, 2026-10-25, after the B2 review):** "colonos a la escala nativa de
  las hojas Body_A del pack (30 px de alto en celda de 32), props ≤ 1 casilla salvo árboles".
  The 24 px target above is replaced; recorded in `docs/art/style.md`. Native-build check: the
  owner does it after merging; not blocking.
- **Licence constraint (pack `Terms.txt`, Anokolisa):** free for commercial use, must not be
  redistributed as assets. This repository is public, so **the pack's PNGs are never
  committed**. Design: `game/assets/pack/` is git-ignored; `tools/sync_pack_assets.ps1` copies
  the exact sheets the game needs from the local pack root (`$env:DEEPHOLM_PACK`, default
  `C:\dev\assets\pixel-crawler`) into `game/assets/pack/` with a manifest of expected files;
  the viewer loads a sprite from the pack when the file exists and falls back to the generated
  placeholder otherwise, so CI, tests and clones without the pack keep working unchanged.
- **Goal of this task:** colonists use the pack's `Entities/Characters/Body_A` sheets (Idle,
  Walk, Carry_Idle, Carry_Walk, and the work animations already mapped in the private notes:
  Slice for chop, Crush for mine/dig) for all four facings, with the glide/animation timing the
  viewer already has; the frame-mapping lives in a JSON next to the sheets
  (`game/data/sprite_frames/colonist_pack.json`), measured from the real sheets (alpha
  bounding boxes), never from memory. Trees, rock, walls, workbench, berries and tools follow
  in a later task (B3) using the same mechanism.
- **Owned paths:** `game/scripts/viewer/colonist_sprites.gd` (+ a small
  `viewer/pack_assets.gd` loader), `game/data/sprite_frames/`, `tools/sync_pack_assets.ps1`,
  `.gitignore`, `game/assets/CREDITS.md` (credit Anokolisa as the terms allow),
  `docs/art/style.md` (a section on pack vs placeholder), tests for the loader fallback.
- **Acceptance:** `tools\sync_pack_assets.ps1` copies the sheets and reports any missing one;
  with the pack present the native build shows pack colonists in all facings and states
  (screenshots in the handoff); without it (`git clean -fdx game/assets/pack`) the game and
  the full suite run exactly as before; `git status` never shows a pack PNG; the owner
  confirms on the native build.
- **Non-goals:** touching the core; changing tile size or colonist size; redrawing anything by
  hand or with AI (owner rule: art comes from the pack or PixelLab, never agent pixels).

### B4 — Two visual bugs from the owner's playtest: progress bar offset, chopped tree shows wall art · `review (antonelmejor50-hub/b4-two-visual-bugs-from)` · *parallel-safe (viewer/tileset only)*

- **Owner (2026-10-25, main `052d8c4`, native build):**
  1. The construction progress bar is drawn "a bit above where it should be" for every
     construction (site). Expected: the bar sits directly above the object's footprint top
     edge (or over the site tile for 1×1), same offset for every object kind, both
     orientations of the workbench, glued to the tile — not to a sprite row.
  2. After chopping a tree, the tile underneath shows **wall art**. Expected: the tile shows
     the terrain it had (grass/sand/dirt) — i.e. the same terrain as its neighbours / what the
     core says the tile is after removal. Find whether the core leaves a wrong tile kind after
     `chop` (then it is a core bug: fix in the removal path with a test) or the viewer's
     terrain atlas maps the post-chop tile to the wrong region (tileset/autotile mapping,
     `tile_atlas_map.gd` / terrain sheet indexes).
- **Owned paths:** `game/scripts/viewer/` (map view, tile atlas map, designation/site
  overlays, colonist/object sprites), `game/data/tilesets/`, `docs/art/terrain-autotile.md`;
  core only if (2) is a core bug: the chop/removal path in `world_state.gd` or `tile_grid.gd`
  (not `*_work_progress*`: R4 owns those) + a headless test proving the tile kind after chop.
- **Acceptance:** before/after screenshots of both cases in the handoff (use the screenshot
  tool in `game/scripts/tools/`); a headless test for the tile kind after chop on each terrain
  (grass, sand, dirt); if the atlas mapping was wrong, a test that every tile kind in
  `tiles.json` maps to an atlas region; full suite passes; the owner confirms on the native
  build.
- **Non-goals:** new art; changing what chopping yields.

---

## Phase A — foundation for scale (owner request, 2026-10-25)

The owner's ambition: thousands of things built on this base — NPCs, stories, levels, maps,
systems — without the base crumbling, with performance and game-development best practices.
Phase R makes `WorldState` modular; it does not by itself prove the architecture carries that
load. Phase A finds out, with evidence, and turns the gaps into backlog entries.

### A0 — Foundation audit against the long-term ambition · `review (antonelmejor50-hub/a0-foundation-audit-against-the)` · *parallel-safe (docs only)*

- **Goal:** `docs/architecture/foundation-audit.md`: an honest, evidence-based assessment of
  whether the current architecture (core/viewer split, actors + components, content registry +
  JSON schemas, job/toil engine, scheduler, routing, regions/rooms, incidents, factions, save
  system, tests) can grow to: 1,000+ actors on screen-sized maps, several map layers
  (underground), hundreds of content kinds (items, objects, recipes, creatures, thoughts),
  scripted stories/events/quests, multiple scenarios/levels, localisation, mods/data packs,
  and a mobile target. For every axis: what already supports it, what will break first and
  why (cite files, functions, line counts, complexity, allocation patterns), and the smallest
  structural change that removes the limit. Measure, do not guess: write and run
  `game/scripts/tests/bench_*.gd` headless benchmarks (tick time vs. actor count 10/100/500/1000
  on a 256×256 map; route search cost; save/load size and time; content load time) and quote
  the numbers; the benchmarks are committed and become the baseline for later tasks.
- **Also audit** against game-architecture best practice for this genre (data-oriented
  simulation, fixed-step determinism, event/message bus vs. direct calls, spatial indexing,
  object pooling, content hot-reload, versioned schemas, replay/debug tooling, headless test
  coverage) and against Godot 4 best practice (scene/resource use, GDScript performance,
  typed code, static typing with `--warnings`, export/mobile constraints).
- **Deliverables:** the audit document; `docs/orca/BACKLOG.md` gains a proposed, ordered set of
  `A*` entries (each with goal / owned paths / acceptance / non-goals, same format as `R*`)
  that the owner will accept or reject — the author does NOT implement them; the benchmarks;
  a one-page summary in plain language (`docs/architecture/foundation-audit-summary.md`, ES)
  for the owner: what is solid, what is not, what it costs to fix, in what order.
- **Owned paths:** `docs/architecture/foundation-audit*.md`, `docs/orca/BACKLOG.md` (append
  only, under Phase A), `game/scripts/tests/bench_*.gd` (new), `docs/orca/handoffs/A0*`.
- **Acceptance:** every claim about the code cites a path (and a function or line range);
  every performance claim cites a benchmark number from a committed `bench_*.gd` run on the
  host, with the command; proposed `A*` entries are concrete and independently reviewable;
  no production code changed (the diff touches only docs and `bench_*.gd`); the full suite
  still passes (benchmarks must not be picked up by `run_tests` as `test_*`).
- **Non-goals:** fixing anything; redesigning for its own sake; changing engine or language.

### Accepted by the owner (2026-10-25)

The entries below come from `docs/architecture/foundation-audit.md` (evidence, file and line
citations) and its summary `foundation-audit-summary.md`. The owner accepted all eighteen on
2026-10-25 (`docs/orca/handoffs/A0.md`), so each is `todo`. Ordered by what breaks first.
"Baseline" means the A0 number quoted in `foundation-audit.md` §2. Every benchmark
target is measured with the same `bench_*.gd` on the same host and quoted before/after in
the handoff. Entries that edit `world_state.gd` run between R steps, never in parallel with
one.

#### A1 — Benchmark runner and baseline report · `todo` · *parallel-safe (tools/docs only)*

- **Goal:** `tools/run_benches.ps1` (promoted from `docs/orca/handoffs/A0-run-benches.ps1`)
  runs every `bench_*.gd` and writes `docs/architecture/bench-baseline.md` (one table per
  benchmark, commit and host in the header). Every later A-task quotes its before/after
  lines from it.
- **Owned paths:** `tools/run_benches.ps1` (new), `docs/architecture/bench-baseline.md` (new),
  `docs/orca/README.md` (one paragraph), `game/scripts/tests/bench_*.gd` (output format only).
- **Acceptance:** the runner reproduces the A0 lines on the host; `run_tests` still ignores
  `bench_*`; no CI gate is added (timings are host-dependent).
- **Non-goals:** performance thresholds in CI; changing what the benchmarks measure.

#### A2 — Allocation-free map queries (cost grid and integer tile keys) · `todo` · R3 done; coordinate with R4 on `world_state.gd`

- **Goal:** `map/passability.gd` (R3) keeps per-tile movement cost and door flags in packed
  arrays, and objects are indexed by integer tile index instead of `"%d_%d"` Strings. The
  route cost callables, regions and rooms read integers. `passability(x, y, faction)` keeps
  its Dictionary signature for callers outside the core. Arrays are updated at the existing
  tile/object mutation points (`_mark_dirty()` call sites). No rule, cost or save field
  changes.
- **Owned paths:** `map/passability.gd`, `map/tile_grid.gd`, `objects/object_table.gd`,
  `map/regions.gd`, `map/rooms.gd`, `world_state.gd` (delegation only), `core-budgets.json`,
  affected tests.
- **Acceptance:** suite PASS; R1/R2-style scenario dump gives byte-identical saves, event logs
  and `state_hash()` against `main`; `bench_route_search` µs/expansion on the generated map
  ≤ 2 (baseline ~8); region full build ≤ 50 ms (baseline 345 ms); rooms no longer re-flood
  when a tile's passability did not change (bench line `rooms on_passability_changed ...
  no passability change` ≤ 1 ms).
- **Non-goals:** changing passability rules or door semantics; layers.

#### A3 — `RouteSearch` with a binary heap and no per-step allocation · `todo` · *parallel-safe (routing only)*

- **Goal:** `routing/route_search.gd` pops the frontier from a binary heap keyed by
  (cost, insertion order), so the order of expansion is exactly today's, and
  `_ordered_neighbors()` uses a constant row-major offset table instead of an allocated,
  lambda-sorted array. `snapshot()`/`restore()` keep their shape. The toil executor stops
  storing a fresh `snapshot()` on every reroute tick (`_begin_go_to_reroute()`,
  `_resume_go_to_reroute()`) and snapshots only when a save encodes.
- **Owned paths:** `routing/route_search.gd`, `scheduling/measured_route.gd`,
  `jobs/toil_executor.gd`, `persistence/state_codec.gd` (only if the snapshot moves to encode
  time), affected tests.
- **Acceptance:** identical paths, statuses and expansion counts for every A0 route case
  (test compares against recorded paths); `test_routing_budget`, `test_reroute`,
  `test_save_reproducibility` unchanged; open-grid d=256 search ≤ 60 ms (baseline 365 ms).
- **Non-goals:** A* or any change to which path is chosen (that is A8).

#### A4 — Need-source candidates per region and a spatial occupancy index · `todo` · combat part after R9

- **Goal:** need-source candidates (`WorldState._need_source_candidates()` /
  `_reachable_candidates_only()`, used by `NeedGiver._start_search()`) are computed once per
  tick per need kind and indexed by region, so a colonist's candidates are a lookup by its
  own region id instead of a pass over every source tile × every colonist. Add one per-tile
  index of actor ids and ground-item ids, owned by `ActorTable` and `ItemTable` and updated
  wherever an actor moves or an item is placed or removed, plus an actor id → actor map. `combat_targeting.gd` `nearest_adjacent_hostile()`,
  `_is_cell_occupied()`, `_colonist_at()`, `_find_colonist()`, `ItemTable.has_item_at()` and
  `get_ground_wood()` use it. Iteration order where it decides a tie stays the same.
- **Owned paths:** `jobs/givers/need_giver.gd`, `actors/actor_table.gd`, `items/item_table.gd`, `combat/combat_targeting.gd`,
  `combat/combat_resolver.gd`, `combat/approach_giver.gd`, `world_state.gd` (delegation),
  `core-budgets.json`, affected tests.
- **Acceptance:** scenario dump identical to `main`; `test_combat`, `test_wolf_attack`,
  `test_incidents`, `test_need_jobs` unchanged; `bench_tick_scaling` idle, 1000 actors: the
  `combat` phase ≤ 5% of its baseline; `needs` workload, 100 colonists: tick 1 ≤ 1 s
  (baseline 147,658 ms), and the 10-colonist tick 1 ≤ 100 ms (baseline 2,010 ms).
- **Non-goals:** exclusive tile occupancy (a rule change); new combat behaviour.

#### A5 — Job storage: id index, retired jobs, read-only views inside the core · `todo` · after R4/R5 (best after R14, still with a migration)

- **Goal:** `JobQueue` indexes live jobs by id. Terminal jobs move to a bounded history (size
  decided in an ADR) instead of staying in `_jobs`. Core callers that only read
  (`HaulGiver`, `ConstructionGiver`, `GlobalAssignment.tick()`, `_advance_colonists()`,
  `ConstructionSystem.active_site_fetch_job_ids()`, the tool toils) get read-only views instead of
  `get_jobs()`/`get_colonists()` deep copies. `JobQueue._emit()` appends in order instead of
  re-sorting the whole list on every event. Public getters used by the viewer keep returning
  copies.
- **Owned paths:** `jobs/job_queue.gd`, `scheduling/global_assignment.gd`,
  `jobs/givers/*.gd`, `jobs/tool_*.gd`, `objects/construction_system.gd`, `world_state.gd`,
  `state_codec.gd`, `save_io.gd`,
  `save_migrations.gd`, `docs/architecture/save-system.md`, an ADR, `core-budgets.json`,
  affected tests and fixtures.
- **Acceptance:** after R14, every schema change carries a version bump, a migration and a
  fixture, and so does this one (v1 → v2, or the next number). R14's reset is one-time and
  covers no later change. If it lands before R14, the same applies within today's chain.
  Terminal jobs leave the save;
  `bench_long_session` retention: the 6,000-tick window within 20% of the 1,000-tick window;
  backlog 2,000 open orders: mean tick ≤ 25% of baseline (235 ms); `test_job_queue`,
  `test_scheduling_fairness` unchanged.
- **Non-goals:** changing the fairness policy (ADR 004) or job states.

#### A6 — Bounded event and dirty-cell streams · `todo` · *parallel-safe (no save change)*

- **Goal:** `EventLog` and `JobQueue` events, and `TileGrid.dirty_cells`, become cursor-based streams
  (`get_events_since(sequence)`, `get_dirty_cells_since(cursor)`) with bounded retention. The
  viewer consumes them incrementally instead of deep-copying the whole log each refresh.
  Events stay unpersisted, as today.
- **Owned paths:** `world/event_log.gd`, `jobs/job_queue.gd` (events only),
  `map/tile_grid.gd` (dirty-cell log), `world_state.gd` (getters), `viewer/map_view.gd`, `viewer/status_text.gd`, `viewer/work_table_panel.gd`,
  `test_architecture_rules.gd` (allow the new getters), affected tests.
- **Acceptance:** event order and content identical for the R1 scenario; event and dirty
  logs stay below their bound in `bench_long_session`; the viewer tests pass.
- **Non-goals:** persisting events; an event bus for module-to-module calls.

#### A7 — Save pipeline: one registry, one pass, compact tiles and routes, off the main thread · `todo` · after A5 (best after R14, still with a migration)

- **Goal:** one `ContentRegistry` per session, injected into `StateCodec`/`SaveIO` instead of
  rebuilt from disk per save and per validation. `write_atomic()` stringifies and hashes
  once. Tiles are saved as a palette plus run-length encoding. In-flight route searches keep their full
  continuation state (`frontier`, `visited`, `came_from` and the accumulated `_cost` per
  visited tile), because a search can span a map change. A re-run against the saved map
  would diverge, and so does today's `restore()`: `_rebuild_costs()` recomputes `_cost` from
  the current map, which can reorder the frontier (audit §4.4). The saved costs are
  restored as they were, and `_rebuild_costs()` is kept only to migrate older saves. The
  encoding becomes compact: `visited` as a tile-index bitset, `came_from` as a 2-bit
  direction per visited tile, `cost` as floats in visit order, `frontier` as ordered tile
  indices, all base64. The file
  write and read-back run on a worker thread after `encode()`. `WorldState` gets `dispose()`
  so a replaced world is freed.
- **Owned paths:** `persistence/*.gd`, `routing/route_search.gd` (snapshot with costs,
  compact helpers, `restore()`),
  `world_state.gd`, `viewer/save_wiring.gd`, `docs/architecture/save-system.md`,
  `contracts/game-state.schema.json`, an ADR, fixtures, affected tests.
- **Acceptance:** after R14, every schema change carries a version bump, a migration and a
  fixture, and so does this one (the next number after A5's, or a shared bump with A5 if they
  land together). If it lands before R14, the same applies within today's chain.
  `test_save_*` unchanged;
  a new test starts a long search, changes passability on a tile the search has already
  visited (and, separately, on a frontier tile) between ticks, saves and loads mid-search,
  then finishes. The visited-tile case changes that tile's cost, not only its passability,
  so it fails on today's cost rebuild. It ends with the same path, status, expansion count and `state_hash()` as
  an uninterrupted run with the same map change. A round trip reproduces `snapshot()` exactly.
  `bench_save_load` 1,000 actors: main-thread save ≤ 150 ms (baseline 1,976 ms total), file
  ≤ 50% of baseline (1,408 KB), `hash_match=true`; leak check delta 0.
- **Non-goals:** changing what is saved, beyond the encoding and the accumulated route
  costs that make the continuation exact; cloud saves.

#### A8 — A* and region-aware routing · `todo` · after A3 · ADR (paths may change)

- **Goal:** `RouteSearch` uses an admissible heuristic (Manhattan × minimum tile cost), so
  expansions grow with distance instead of distance squared. Unreachable targets are refused
  by the region check before a search starts, everywhere (not only in the scheduler). The ADR
  records the new deterministic tie-break and accepts that equal-cost paths may differ from
  today's.
- **Owned paths:** `routing/route_search.gd`, callers that start searches, an ADR,
  `docs/architecture/orders-and-movement.md`, affected tests.
- **Acceptance:** path lengths equal to Dijkstra's on every A0 case; d=256 on the generated
  map ≤ 1,500 expansions (baseline 15,462) and ≤ 25 ticks to route (baseline 242);
  determinism tests updated with the ADR quoted.
- **Non-goals:** hierarchical pathfinding (only if A8's numbers are not enough).

#### A9 — Viewer at 1,000 actors · `todo` · after A5/A6

- **Goal:** the viewer reads one read-only snapshot per tick instead of several deep-copying
  getters. Actors are drawn batched (one `MultiMeshInstance2D` or one `_draw()` per layer
  rather than 4–6 nodes each). `colonist_panel`/`work_table_panel` update rows instead of
  rebuilding them every tick. `TickDriver` caps catch-up ticks per frame. The viewer-purity
  rule also rejects `world._field` access, and the six known reads (including
  `debug_scenario.gd` writing `world._items`) go through public API or commands.
- **Owned paths:** `game/scripts/viewer/*.gd`, `boot.gd`, `world_state.gd` (snapshot getter),
  `test_architecture_rules.gd`, viewer tests, a new `bench_viewer_refresh.gd`.
- **Acceptance:** `bench_viewer_refresh` (headless refresh of 1,000 actors) ≤ 4 ms per tick;
  purity test fails on a planted `world._x` read; manual run shows the same screen.
- **Non-goals:** new art or UI features.

#### A10 — Static typing gate for the core · `todo` · *parallel-safe*

- **Goal:** `project.godot` enables `untyped_declaration`, `inferred_declaration` (off),
  `unsafe_property_access`, `unsafe_method_access` and `unsafe_call_argument` as warnings. A
  CI step counts warnings under `game/scripts/core` against a committed baseline file and
  fails when the count rises. The 102 untyped `var x =` in core are typed where it is
  mechanical.
- **Owned paths:** `game/project.godot` (`[debug]` only), `.github/workflows/ci.yml`,
  `tools/` (counter script), `docs/architecture/warnings-baseline.txt`, core files (type
  annotations only, no logic).
- **Acceptance:** CI fails on a planted untyped declaration in core; scenario dump identical;
  suite PASS.
- **Non-goals:** typed entity classes (a data-model change, not a gate).

#### A11 — Command recording and headless replay · `todo` · *parallel-safe*

- **Goal:** the viewer can record a session's seed, content version and command stream to a
  file. `tools/replay.ps1` replays it headless and checks `state_hash()` checkpoints recorded
  every N ticks, printing the first diverging tick.
- **Owned paths:** `game/scripts/core/world/replay_log.gd` (new, plain data),
  `viewer/save_wiring.gd` or a new viewer module, `tools/replay.ps1`, a test, docs.
- **Acceptance:** a test records 500 ticks with mixed commands, replays them and matches every
  checkpoint; a planted nondeterminism is reported at the right tick.
- **Non-goals:** network play; a replay viewer UI.

#### A12 — Map layers: coordinate model ADR · `todo` · *parallel-safe (docs only)* · before F4

- **Goal:** an ADR that chooses how a tile is addressed across layers (layer next to
  `Vector2i`, `Vector3i`, or one flat index with per-layer offsets). It covers how
  passability, regions, rooms, routing (stairs and ramps as edges), saves (migration from
  single-layer) and the viewer handle layers, and the inventory of what must change (506
  `Vector2i` sites and the four String key formats in core).
- **Owned paths:** `docs/decisions/0xx-map-layers.md`, `docs/architecture/map-experience.md`,
  `docs/orca/BACKLOG.md` (F4 entry).
- **Acceptance:** the owner signs off the ADR; F4's Design block can cite it.
- **Non-goals:** any code.

#### A13 — Content packs: one registry per session, ordered roots, strict ids · `todo` · after R12

- **Goal:** `ContentRegistry` is built once per session from an ordered list of roots (base,
  then packs). Each root may append entries or override entries by id, under explicit rules.
  Duplicate ids within a root are an error (today they silently overwrite). The validator
  gains `enum`. `SaveIO` validation reads its tile, job and need whitelists from the registry
  instead of literals. Saves record the pack list.
- **Owned paths:** `content/content_registry.gd`, `persistence/save_io.gd`,
  `persistence/state_codec.gd`, `calendar/calendar_service.gd`, `world_state.gd`
  (injection), `boot.gd`, ADR 010 amendment, schemas, tests.
- **Acceptance:** a test pack adds an item and overrides a tile, and both load headless; a
  duplicate id fails with `schema_violation`; a save with a missing pack fails with a typed
  error; the real bundle loads unchanged.
- **Non-goals:** script mods; a mod browser UI.

#### A14 — Data-driven work effects · `todo` · after R11

- **Goal:** `jobs.json` gains an `effects` block (tile transform, always-yields, find table).
  `_toil_on_work_complete()`'s per-kind `match` for dig, chop, mine, forage, till and sow is
  replaced by one generic application of that block, so a new work kind is a content entry.
  The `spawn_wood_item`/`spawn_stone_item`/`spawn_berries_item` special cases fold into one
  spawn by item id where behaviour allows.
- **Owned paths:** `jobs/toil_bindings.gd` (R11), `items/item_table.gd`, `content/jobs.json`
  and schema, `content_registry.gd` (cross-checks), `extension-points.md`, an ADR, tests.
- **Acceptance:** every existing work kind produces identical results (scenario dump equal to
  `main`); a test adds a new work kind via content only.
- **Non-goals:** recipes and workbenches (F2).

#### A15 — Localisation-ready text · `todo` · *parallel-safe after A9*

- **Goal:** the core returns reason codes and parameters only (the English `message`
  strings move to `data/text/en.json`). Every visible viewer string is a `TextTable` key, and
  `TextTable` loads `data/text/<locale>.json` with `en` as the fallback. Content labels
  become keys.
- **Owned paths:** `commands/command_checks.gd`, `world_state.gd` (message strings),
  `viewer/*.gd`, `data/text/*.json`, `content/tiles.json`/`calendar.json` labels and schemas,
  a lint test.
- **Acceptance:** a lint finds no user-facing literal in the viewer; a pseudo-locale test shows
  every key resolves; rejection reason codes are unchanged (grep the tests).
- **Non-goals:** translations themselves; font and RTL work.

#### A16 — Scenarios as content · `todo` · after R12

- **Goal:** a `scenarios.json` kind with a schema (map size, seed or fixed map, starting
  roster, items and objects, enabled incidents, calendar). New game builds a world from a
  scenario entry, and `debug_scenario.gd` becomes the first entry.
- **Owned paths:** `content/scenarios.json` and schema, `content_registry.gd`,
  `world_state.gd` or a new `world/scenario_builder.gd`, `viewer/new_game_dialog.gd`,
  `viewer/debug_scenario.gd`, an ADR, tests.
- **Acceptance:** two scenarios build headless with deterministic `state_hash()`; the default
  new game is byte-identical to today's.
- **Non-goals:** win/lose conditions (A17); a campaign.

#### A17 — Story and quest layer: design ADR · `todo` · *parallel-safe (docs only)*

- **Goal:** an ADR for trigger → condition → effect rules evaluated by one story giver (job
  giver pattern, ADR 011). Effects are ordinary commands. Flags and quest stages are persisted
  module state. Incidents become one effect kind. It includes a content schema sketch and
  three worked examples (a migrant chain, a raid warning, a first-winter quest).
- **Owned paths:** `docs/decisions/0xx-story-layer.md`, `docs/architecture/extension-points.md`.
- **Acceptance:** the owner signs off the ADR; it names the code tasks it would create.
- **Non-goals:** any code.

#### A18 — Mobile spike: measure before committing · `todo` · *parallel-safe*

- **Goal:** an Android export preset, a stretch mode, and touch pan and zoom. The A0
  benchmarks run on one reference phone to get the real device factor. An ADR decides
  whether the tick moves to a worker thread with a snapshot handed to the viewer.
- **Owned paths:** `game/export_presets.cfg`, `game/project.godot` (display/input),
  `viewer/map_viewport.gd` (touch), an ADR, `foundation-audit.md` (appendix with device
  numbers).
- **Acceptance:** the APK runs the game on the reference device; the bench lines from the
  device are in the appendix; the ADR records the decision.
- **Non-goals:** store release; iOS.

---

## Phase F — towards the baseline (after R12; designs to be closed with the owner first)

Order follows `../design/baseline.md` §"Suggested order". Each entry is a placeholder until
the owner has answered its design questions in a chat session and the answers are written
into the entry. Do not start an `F*` whose **Design** block says *pending*.

### F1 — Crops: growth stages and harvest on tilled/sown tiles · `todo` · Design: *pending*

Questions: growth time per crop (days), stages visible, what harvest yields and where it
goes, drought/season failure rule, farm zone vs. per-tile orders.

### F2 — Workbench recipes and item groups · `todo` · Design: *pending*

Questions: first recipes (planks? stone blocks?), queue vs. target counts, who crafts
(labour), where output goes.

### F3 — Skills and XP per labour · `todo` · Design: *pending*

### F4 — Underground layers, tunnel, ores, supports and cave-ins · `todo` · Design: *pending*

The largest gap and the game's identity. Needs a map model that supports several layers
(prepared by R3's `TileGrid`).

### F5 — Stockpile filters, remaining labours, happiness/thoughts · `todo` · Design: *pending*

### F6 — Farm/forest/pasture zones, animals · `todo` · Design: *pending*

### F7 — Squads, raids, traps · `todo` · Design: *pending*

### F8 — Health, wounds, medic, death and burial · `todo` · Design: *pending*

### F9 — Room quality, furniture, trade, statistics, campaign modes · `todo` · Design: *pending*

---

## Parked (owner decisions recorded, not scheduled)

- Left-side action panel (Tasks / Build / Select / Colony / Military) — later.
- Fill trenches back — later.
- Month/year calendar on top of days, starvation rule, "gone crazy" rule — owner decisions
  pending (see `../design/baseline.md`).
- `test_save_migration` integrity mismatch on Linux Godot (passes on Windows) — platform
  hash difference, worth a task once the core is split.
- Found during R2 (pre-existing on `main`, not fixed in a refactor; see `handoffs/R2.md`):
  - `StateCodec._encode_work_progress_owners()` splits a `rescue` job's job-scoped
    work-progress key on `_` and writes an out-of-map tile (`{x: 0, y: 17244}`), so
    `SaveIO.write_atomic()` refuses that save with `invalid tile coordinates`. Fits R4.
  - `state_hash()` does not cover ground berries: two worlds that differ only in
    `groundBerries` hash equal although the field is persisted and drives `eat_food`.
  - Ground-berries factions are never persisted: after a load,
    `get_ground_berries_faction_id()` returns `""` for berries that were `"colony"`.
