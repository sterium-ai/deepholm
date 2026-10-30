# ADR 061: Workbench recipes, the craft labour and item groups

> **In short:** Recipes are content (`recipes.json`). Each built workbench has "keep N in
> stock" targets and a queue of orders. A new `CraftingSystem` picks one recipe at a time for
> each bench (a *bill*), as long as its inputs are in a stockpile. A `CraftGiver` then submits
> `craft_fetch` jobs, which haulers do with the construction-site fetch mechanism, and one
> `craft_work` job for a colonist with the `craft` labour. The output appears next to the
> bench and is hauled to a stockpile. Items declare groups for later stockpile filters. Bench
> state is saved (schema v7).

- **Status:** accepted (design closed with the owner on 2026-10-29, `BACKLOG.md` F2)
- **Date:** 2026-10-30
- **Scope:** content (`recipes.json`, `items.json` groups, two job kinds), simulation (one
  module, one job-giver, one tick phase, three commands), persistence (schema v7,
  `crafting`), presentation (a minimal workbench panel)
- **Depends on:** ADR 011 (one work engine), ADR 040/043 (construction sites and the
  site_fetch mechanism), ADR 013 (tool items), ADR 048 (composed core, size rule), ADR 051
  (data-driven work effects), ADR 052 (codes in the core, words in `data/text`)
- **Implements:** BACKLOG F2

## Context

The baseline needs a production chain: tools and materials made from what colonists gather.
The owner's design (BACKLOG F2): recipes as content on the existing 2x1 `workbench`; v1
recipes axe (3 wood + 1 stone), pick (2 wood + 2 stone), planks (1 wood -> 2 planks) and
stone blocks (2 stone -> 1 block); production requested per bench by a stock target and by a
queue of orders; a new `craft` labour does the work; inputs reach the bench through the
construction-site fetch mechanism; the output appears next to the bench and is hauled to a
stockpile; items declare the groups `tool`, `material`, `food` and `seed`.

`world_state.gd` was full (at its cap once A7 and F1 land). The site_fetch mechanism, and the
completion hook a work job needs, live in the job engine (`job_queue.gd`, `toil_bindings.gd`),
outside the owned paths F2 listed, so the owner approved minimal edits there (2026-10-30, see
the F2 entry).

## Decision

### Content

- `content/recipes.json` (+ `schemas/recipes.schema.json`): `{id, bench, inputs: [{item,
  quantity}], outputs: [{item, quantity}]}`. An optional collection kind
  (`ContentRegistry.OPTIONAL_COLLECTION_KINDS`), so an older content root without the file
  still loads (with no recipes). `ContentRegistry._check_crafting_content()` rejects, as
  `dangling_reference`, a recipe whose bench is not an object kind or whose input/output is
  not an item id; and, as `schema_violation`, a recipe listing an item twice in its inputs (or
  outputs) or a quantity above `RecipeBook.MAX_COUNT` (999). That one constant also caps target
  and order counts and a saved bill's held quantity (`CraftingValidator`), so every recipe the
  registry accepts can be saved.
- `content/items.json` gains `planks` and `stone_blocks` (kind `material`) and a top-level
  `groups` list. **An item's `kind` is its group**: the existing field already carried
  `tool`/`material`/`seed`, so no second field was added. When `groups` is declared, an item
  whose kind is not listed is rejected. The list is `tool, material, food, seed, valuable`:
  `valuable` is kept because `gold_coin` already used it (the design listed the four groups
  F5 needs; dropping `gold_coin`'s group would have been a content change outside F2).
- `content/jobs.json` gains `craft_fetch` (labour `haul`, site_fetch's toils `reserve, go_to,
  pick_up, go_to, deposit, release_all`) and `craft_work` (labour `craft`, `reserve, go_to,
  work, release_all`, `work_ticks` 60). The `craft` labour was already in the labour table
  (`actors.json`, `WorldState.LABOUR_KINDS`).

### State: `core/crafting/`

`CraftingSystem` (composed into `WorldState` like `ConstructionSystem`; `RecipeBook` reads
`recipes.json`) keeps, for each configured bench (keyed by the origin of a colony object whose
kind is some recipe's `bench`):

- `targets`: recipe -> N, "keep N in stock" (a target of 0 removes it);
- `orders`: `[{id, recipe, remaining}]`, ids `order_<n>` from a persisted counter;
- `bill`: `{}` or `{recipe, order_id, held}`, the one recipe being made now and the inputs
  already delivered to it (`order_id` is `""` for a target).

Rules, run once a tick by `update_bills()` before any job is submitted:

1. A bench whose object is gone (removed, destroyed) loses its record; its craft jobs are
   cancelled (a carried load dropped first) and its held inputs dropped next to the bench.
2. A bill that is not met, has no craft_fetch in flight and can no longer be met from the
   stockpiles is **abandoned**: its held inputs go back to the ground next to the bench (and
   are hauled back like any loose item) and the bench is free again.
3. An idle bench takes the first **order** (queue order), else the first **target** below
   stock (recipe id order), **whose inputs are all available**: stockpiled, not reserved, not
   named by a live site_fetch/craft_fetch job, and not already claimed by another bench's
   bill. A recipe whose inputs are missing is skipped, so it never blocks the orders behind it.

"Stock" (for targets) is the design's *stockpiled* count of the recipe's first output: loose
units on a stockpile tile and tool items stocked in a stockpile, plus units a haul is taking to
a stockpile right now (a loose item named by a queued or active haul job that is not blocked,
or what a colonist on a haul job carries). The haul term keeps an output waiting for its hauler
from being made twice; a blocked haul (an item no colonist can reach, or no free stockpile cell)
does not count, so an unreachable item never suppresses its target. A tool held by a colonist
or lying outside a stockpile leaves the stock, which is what re-triggers a target.

### Jobs: `CraftGiver` and the shared fetch mechanism

`CraftGiver` (`core/jobs/givers/craft_giver.gd`, TickPipeline phase `craft_giver`, right
after `construction_giver`, before the scheduler) persists nothing; it reads what is in
flight from the job queue every tick. Per bench with a bill:

- while inputs are short: **one craft_fetch at a time**, from the lowest-id free stockpiled
  source of the first short input; `site` is the bench origin (`JobQueue.attach_site()`);
- once all inputs are held: **one craft_work** at the bench origin (reserving its `tile:`
  key, so one crafter per bench).

`craft_fetch` *is* a site_fetch for the job engine: `JobQueue.FETCH_KINDS =
[site_fetch, craft_fetch]` drives activation (reserve only the source item), reactivation,
`restore()`, the delivering flag (`cell` = `site`) and `job_index.gd`'s designation
exclusion; `ToilBindings` routes the delivering leg to `site`, fails an unreachable fetch and
drops cargo like site_fetch. What differs is small and explicit: the deposit target id is the
bench's bill (`CraftingSystem.BILL_PREFIX + "x,y"`; `deposit_target_exists()`/`deposit_into()`
dispatch on that prefix and hand any other id to `ConstructionSystem`), the pick_up is
clamped to what the bill still needs, a craft_fetch never chains to a second source or a
sibling site (leftover hands are dropped), and it is never retargeted on activation (the
seed source is the lowest id, like ConstructionGiver's seed). The code paths that drop a
carried haul/site_fetch load on cancel, trap, need-resume and refusal name craft_fetch too.

`craft_work` is an ordinary work job: its progress lives in `WorkProgress` (saved), and its
completion arm in `ToilBindings._toil_on_work_complete()` calls
`CraftingSystem.complete_craft()`: the held inputs are spent, the outputs are placed as one
stack each on the first passable, item-free tile next to the bench footprint, the order is
counted down (removed at 0) and the bill cleared. An unreachable craft_work is cancelled (like
site_work) and resubmitted by the giver.

### Crafted tools

Axes and picks are identity-bearing `ToolItemStore` items, but haul moves only stackable
`ItemTable` items. A crafted tool therefore appears as a stackable item next to the bench, is
hauled like any output, and `CraftingSystem.stock_tools()` (start of the craft_giver phase)
turns every loose tool stack lying free in a stockpile into tool items on that cell. From then
on `fetch_tool` can take it. No ItemTable tool stack existed before F2, so the conversion
changes nothing in an older world.

### Commands

`craft_set_target {x, y, recipe, count 0..999}`, `craft_add_order {x, y, recipe, count
1..999}` (applied result carries `order_id`) and `craft_cancel_order {x, y, order_id}`;
`(x, y)` is any tile of the bench. Handled by `commands/handlers/crafting_handler.gd`
(created by `CommandRouter`, so `world_state.gd` gains no line); the rule is
`CraftingSystem.check_command()`, shared with `preview()`. Rejections: `invalid_target`
(`not_a_workbench`, `recipe_wrong_bench`, `unknown_craft_order`) and `invalid_payload`
(`unknown_recipe`, `craft_count_out_of_range`, `craft_payload`, `craft_extra_field`).
Cancelling the order a bill serves ends the bill like an abandon.

### Persistence (schema v7)

Top-level `crafting = {benches: [{x, y, targets: [{recipe, count}], orders: [{id, recipe,
remaining}], bill: null | {recipe, orderId, held: [{item, quantity}]}}], nextOrderId}`,
always written, optional on the wire (absent = no configured bench), validated by
`validators/crafting_validator.gd`. Migration v6 -> v7 adds `{benches: [], nextOrderId: 1}`.
A delivering craft_fetch's route resumes with the bench's target-tile exception
(`StateCodec`), since the bench is impassable. `state_hash()` covers `crafting` once a bench
was configured (so every pre-F2 world keeps its hash); bills, held inputs, orders and targets
all differ in the hash.

F2 takes v7, the next free number on `main` at rebase time: F1 (crops, ADR 059) landed first
with v5 -> v6 (`crops`) and `save_schema_v6_fixture.json`, both kept as they are; F2's step
follows it and its fixture is `save_schema_v7_fixture.json` (the same session).

### Presentation

`viewer/workbench_panel.gd`, in the info column: one block per colony workbench, a row per
recipe with its target (- / +) and "Order 1", the bill in progress, the queue and "Cancel next
order". It reads `WorldState.get_crafting_benches()` and only issues the three commands.
Planks and stone blocks have no ground icon yet (placeholder entries in `world_pack.json`).

## Alternatives considered

- **Craft bills as construction sites.** Reusing `ConstructionSiteTable` records would have
  avoided the `FETCH_KINDS` list but leaked into ConstructionGiver, finalize and the
  enclosure check. Rejected.
- **Materials hauled to a ground cell by the bench, consumed by the crafter.** That needs no
  job-engine edit, but HaulGiver would haul them straight back to the stockpile, and it is not
  the design's "site_fetch-style reservations". Rejected.
- **Several craft_fetch jobs per bench at once (like ConstructionGiver's max_builders).** One
  at a time is simpler and deterministic, and fast enough (the acceptance run finishes in 651
  of its 4,400 ticks). Revisit if production statistics (later) show benches waiting on haulers.
- **Recipe-specific work durations.** Kept out of v1: one `craft_work` `work_ticks` keeps
  WorkProgress unchanged. A `work_ticks` per recipe needs a resume hook like site_work's.
- **Crafted tools as tool items straight away.** There is no haul for tool items; spawning
  them in the stockpile would skip "appears next to the bench and is hauled". Rejected.

## Consequences

- One more tick phase (`craft_giver`); a world with no configured bench pays one pass over
  the item table (`stock_tools()`) and the craft/fetch job views each tick.
- `JobQueue.FETCH_KINDS` is the place a future fetch-to-a-target kind joins.
- F5 (stockpile filters) reads groups from `items.json`; no filter exists yet.
- Not in v1 (BACKLOG non-goals): more workshops, production statistics, filter UI, tool
  quality, skill-gated recipes, recipe work durations, ground icons for planks/blocks.

## Acceptance criteria

- [x] `docs/architecture/save-system.md`, `colonist-ai.md` and `core/commands/README.md`
  updated.
- [x] `game-state.schema.json` (v7, `crafting`), content schemas, fixture
  `save_schema_v7_fixture.json` and tests (`test_crafting.gd`, `test_save_migration.gd`,
  `test_architecture_rules.gd`) updated.
- [x] Save/migration impact handled (v6 -> v7).
- [x] The source-of-truth index still points to the authoritative locations (no new
  canonical document).
