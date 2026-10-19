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

### R0b — Stop `godot --import` from dirtying the worktree · `review` · *parallel-safe*

- **Goal:** after `godot --headless --path game --import` on a fresh checkout, `git status` is
  clean. Today 31 `game/assets/generated/**/*.png.import` files come back modified by line
  endings only (committed with CRLF, rewritten with LF, or the reverse). Normalise them once and
  pin the rule in `.gitattributes` so it cannot drift again.
- **Owned paths:** `.gitattributes`, `game/**/*.import`, `game/README.md` (one line).
- **Acceptance:** on a fresh worktree, run the import twice and `git status --porcelain` prints
  nothing; `git diff --stat main` shows only line-ending changes (`git diff -w --stat` empty);
  CI import + boot steps still pass.
- **Non-goals:** touching `.tres`, `.uid`, scripts or any content.

### R1 — Extract `EventLog` · `review` (branch `antonelmejor50-hub/r1-extract-eventlog`)

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

### R2 — Extract `ItemTable` · `todo`

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

### R3 — Extract `TileGrid`, `ObjectTable`, `ZoneTable`, `Passability` · `todo`

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

### R4 — Extract `WorkProgress` · `todo`

- **Goal:** `jobs/work_progress.gd` owns `_work_progress`, `_work_progress_owner`,
  `_suspended_work_progress` and every function that reads or writes them, including the
  load-time owner reconstruction. Persisted field names unchanged
  (`workProgress`, `workProgressOwners`, `suspendedWorkProgress`).
- **Owned paths:** `world_state.gd`, `jobs/work_progress.gd` (new), `state_codec.gd`,
  `core-budgets.json`, affected tests.
- **Acceptance:** as R1; `test_save_migration` and the suspend/resume tests unchanged.

### R5 — Extract `ConstructionSystem` · `todo`

- **Goal:** `objects/construction_system.gd` owns sites and the whole construction flow
  (submission, footprint/terrain checks, site fetch source selection, site work, finalize,
  cancel, enclosure check, build-line batching). `construction_giver.gd` talks to it, not to
  `WorldState`.
- **Owned paths:** `world_state.gd`, `objects/construction_system.gd` (new),
  `objects/construction_site.gd`, `jobs/givers/construction_giver.gd`, `state_codec.gd`,
  `core-budgets.json`, affected tests.
- **Acceptance:** as R1; `test_build`, `test_wall_orders`, the site-fetch tests unchanged.

### R6 — Extract `TrenchSystem` · `todo`

- **Goal:** `actors/trench_system.gd` owns trapping, climb-out, escape job submission,
  rescue candidate/victim pools and rescue reasons; `rescue_giver.gd` depends on it.
- **Owned paths:** `world_state.gd`, `actors/trench_system.gd` (new),
  `jobs/givers/rescue_giver.gd`, `state_codec.gd`, `core-budgets.json`, affected tests.
- **Acceptance:** as R1; `test_trapped_actors`, `test_rescue` unchanged.

### R7 — Extract `TradeSystem` · `todo`

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

### R13 — Split `boot.gd` · `review` (branch `antonelmejor50-hub/r13-split-boot-gd`, report `handoffs/R13.md`) · *parallel-safe (viewer only, no core files)*

- **Goal:** `game/scripts/boot.gd` becomes scene composition only; new-game setup, save
  wiring and input wiring move to `viewer/` modules. Under 300 lines.
- **Acceptance:** headless boot check passes; manual run shows the same screen and tools.

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
