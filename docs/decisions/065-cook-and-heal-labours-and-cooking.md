# ADR 065: The cook and heal labours, the kitchen and meals

> **In short:** A 2x1 `kitchen` is a second F2 bench. Its one recipe, `meal` (2 raw `food` ->
> 1 `meal`), is made by the F2 machinery unchanged (targets, orders, bills, `craft_fetch`).
> Its work job is a new `cook_work` kind under the existing `cook` labour, which a recipe
> selects with an optional `job` field. Items gain an optional `satiety`: a hungry colonist
> eats the most filling reachable food, so a meal (100) comes before raw food (40). `heal` joins
> the labour table and the skills as an empty slot for later work. Saves move to schema v12
> (`heal` added to every colonist's labour table and skills).

- **Status:** accepted (design closed with the owner on 2026-10-30, `BACKLOG.md` F5b)
- **Date:** 2026-11-03
- **Scope:** content (`kitchen`, `meal`, `satiety`, `cook_work`, the `heal` labour),
  simulation (`RecipeBook.work_kind_of`, `CraftGiver`, the toil binding for `cook_work`,
  `NeedsSystem`'s food sources), persistence (schema v12, one migration step)
- **Depends on:** ADR 061 (workbench recipes, F2), ADR 062 (skills and XP per labour, F3),
  ADR 011 (one work engine), ADR 051 (data-driven work effects)
- **Implements:** BACKLOG F5b

## Context

The owner's design (BACKLOG F5b, closed 2026-10-30) asks for two new labours, `cook` and
`heal`, and for cooking: a 2x1 kitchen, a meal recipe from raw food, and a hungry colonist who
eats a meal before raw food. Healing has no work yet; only its labour-table entry and skill
slot ship now. Spoilage, quality and cooking-skill effects beyond F3's speed are non-goals.

The `cook` labour was already in the labour table and skills (it shipped with the slice, unused);
only `heal` is new. `world_state.gd` is at its 800-line cap and must not grow. Zones and the
`ZoneTable` belong to F5a/F6a and are not touched.

## Decision

### Content

- `objects.json`: `kitchen`, a rotatable 2x1 impassable object like the workbench
  (`build_ticks` 120, `max_builders` 2, cost 2 wood + 5 stone). Built and fetched for
  through the existing construction-site path.
- `recipes.json`: `meal`, bench `kitchen`, `job: "cook_work"`, 2 `food` -> 1 `meal`. The
  recipe schema gains an optional `job` (enum `RecipeBook.WORK_KINDS`: `craft_work`,
  `cook_work`); without it a recipe keeps F2's `craft_work`.
- `jobs.json`: `cook_work`, labour `cook`, toils `reserve, go_to, work, release_all`,
  `work_ticks` 60: `craft_work`'s shape under another labour. So the labour table, the
  scheduler's labour filter and F3's skill speed and XP apply to cooking with no new code.
- `items.json`: an optional `satiety` (integer >= 1) makes an item edible: `food` 40,
  `meal` 100 (a full food need is 100).
- `actors.json` / `WorldState.LABOUR_KINDS` / `skills.schema.json`: `heal` appended as the
  eighth labour. It has no job kind, so its level only orders nothing; it is the slot later
  healing work will use.

### Simulation

- **One bench machinery.** `RecipeBook.work_kind_of(recipe)` gives the work kind;
  `CraftGiver` submits that kind instead of a hard-coded `craft_work`, `CraftingSystem`
  watches `["craft_fetch"] + WORK_KINDS`, and `ToilBindings` binds `cook_work`'s `work`
  completion to the same bill completion as `craft_work`. Inputs still come by
  `craft_fetch` (labour `haul`); the meal appears next to the kitchen and is hauled to a
  stockpile like any F2 output.
- **Eat preference** (`NeedsSystem`). The food need's sources are berry bushes (restore =
  `needs.json`'s food restore, 100) and, new, tiles holding an unreserved edible ground item
  (restore = its best item's `satiety`). After the reachability filter, only the candidates of
  the highest satiety tier are kept; the nearest of those wins as before. Eating a tile takes
  one unit of its most filling unreserved item, else one berry. A meal therefore goes before
  nearer raw food, and raw food is eaten when nothing better is reachable. `consume`'s
  validity check is "the target still has satiety > 0", so a meal taken by someone else fails
  typed (`source_gone`) as a berry bush did.
- Items reserved by a haul or fetch (`JobQueue.ITEM_KEY_PREFIX`) are never eaten.

### Persistence: schema v12

v12 (the v11 -> v12 step, after F5a's v10 and F6a's v11) adds `heal` to each colonist's
`labourTable` (level 3, the spawn default) and `skills` (`{level: 0, xp: 0}`), keys sorted. The
step refuses a state whose colonist already has `heal` or lacks either map. Nothing else
changes: kitchens, meal bills and meal items are ordinary F2 bench and item state.

## Consequences

- A second production bench costs content only: a new recipe names its bench and, if it is not
  `craft_work`, its work kind.
- A meal ties with a berry bush (both 100); the nearest wins. Raw food never beats a bush.
- Making raw `food` edible lets hungry colonists eat stockpiled food when no bush is reachable,
  as well as cook it; there is no reservation of food for the kitchen.
- `heal` shows in the work table and the skill list but enables no job until healing ships.
- New worlds seed one more skill per colonist from the same seeded generator
  (`world_seeding.gd` draws per labour in table order), so a given seed now gives different
  starting levels for the other labours than before F5b. Saves are unaffected: migrated colonists
  keep their levels and get `heal` at zero.
- Tests: `test_cooking.gd` (acceptance, eat preference, save/load mid-fetch and mid-cook,
  replay), `test_save_migration.gd` (the v11 -> v12 step and the committed
  `save_schema_v12_fixture.json`, written by `docs/orca/handoffs/F5b-write-save.gd`), `test_architecture_rules.gd` (the kitchen
  execution trace).
