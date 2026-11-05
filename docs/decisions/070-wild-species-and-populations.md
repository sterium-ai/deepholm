# ADR 070: Wild species, animal actors and population dynamics

> **In short:** Six wild species are defined in `content/species.json` (grasshopper, bird, fox,
> rabbit, deer, wolf). Each species has a diet (a grazer eats tiles; a predator eats other
> species), a speed, a hunger time, a starvation window, an adult age, breeding rules and a
> population cap. Animals are actors of kind `"animal"` (faction `wildlife`) and live on the
> surface only. They are rows of the shared actor table, like colonists and raiders, and
> `FaunaSystem` drives them once per tick in a new `"fauna"` TickPipeline phase. All of its random draws come from its own salted RNG
> stream. Births are logistic: once a breeding pair qualifies, a birth happens with probability
> `1 − count / cap`. Shipped `mapgen.animal_counts` seeds starting counts for every new world.
> Saves move to schema v15: animals are entities of kind `"animal"`, and an optional `fauna`
> field carries the id counter and the fauna stream. The viewer draws the wolf with the B3 pack art and
> the other species as coloured placeholder dots.

- **Status:** proposed (design closed with the owner in BACKLOG F6b, package 1 of 3 = F6b-1)
- **Date:** 2026-11-03
- **Scope:**
  - content: `species.json` and its schema, plus `mapgen.animal_counts`, and the manifest's
    `content` list;
  - simulation: `FaunaSpecies`, `FaunaSystem`, `ActorTable.spawn_animal()`, the TickPipeline
    `"fauna"` phase;
  - persistence: schema v15, the `"animal"` entity kind (`EntityCodec`, `EntityValidator`) and
    `FaunaValidator`;
  - presentation: `actor_sprites.gd`.
- **Depends on:** ADR 064 (schema v14, F5a-b), ADR 066 (schema v13), the A9 view snapshot, B3 actor art, A14 tick budgets
- **Implements:** BACKLOG F6b-1

## Context

F6b brings wildlife whose numbers balance themselves. Package 1 (this ADR) covers species,
animal actors and population dynamics. Package 2 adds the effects of imbalance (crop damage and
similar), and package 3 adds combat and hunting.

The acceptance cases are:
- 20 grasshoppers alone reach their cap and stay there;
- adding 2 birds keeps the grasshoppers below the cap, and the birds survive;
- a wolf with no prey starves within its window;
- 200 animals alongside 1000 colonists stay within the tick budget, with a deterministic hash
  and identical save/load and replay.

Non-goals: crop damage, fertility, disease, hunting, combat, pasture and underground animals.

The owner note adds four constraints:
- animals live on the surface only;
- they run in their own phase, with a deterministic RNG;
- `world_state.gd` must not grow (it is 767 lines);
- the A14 budget must be measured and cited.

## Decision

1. **Content.**
   - `species.json` lists the species. Times are given in days and compiled to ticks by
     `FaunaSpecies.build()`, using `steps_per_day`, `hungry_after_days`, `starve_days`,
     `adult_days`, `reproduction.interval_days`, `cap`, `sight`, `health` and `attack`.
   - A grazer's `eats` refers to tile groups (`grass_tiles`, `crop_tiles`); a predator's `prey`
     refers to species ids.
   - `build()` rejects unknown tiles, duplicate ids, unknown prey and bad mapgen counts, with a
     clear message.
   - A rejection is fatal at startup: `FaunaSystem.startup_error()` returns
     `fatal fauna content error (invalid_species_content): <message>`, and `WorldState` passes it
     to `_fail_startup()` together with the table errors. The world never starts animal-free on
     bad content (review fix; `test_fauna_startup.gd` runs the real startup in a child process).
   - `health` and `attack` are stored but not yet used; they are for F6b-3.
   - **Manifest** (owner decision, review round 3, BACKLOG commit e9292ad): `species.json` is
     referenced in `content/manifest.json` like any other content file. The manifest schema gains
     an optional `content` array of file names, and the shipped manifest lists every content
     file. `ContentJson.manifest_reference_error()` refuses an entry that names a file the bundle
     lacks, the manifest itself, or a file twice, with a typed `missing_file` error naming
     `manifest.json`. The field stays optional, so a bundle without it (the test fixtures) loads
     as before.
2. **Actors.** An animal is a flat record with these fields: `id` (`animal_<n>`),
   `kind: "animal"`, `species`, `x`, `y`, `z`, `factionId: "wildlife"`, `bornTick`,
   `lastMealTick`, `nextBirthTick` and `health`.
   - `ActorTable.spawn_animal()` creates the record.
   - **The records are rows of the shared actor table** (owner decision, round 1): the same list
     as colonists and raiders, indexed by the same `ActorIndex`. `FaunaSystem` holds no list of
     its own; it reaches the table through four callables from `WorldState` (read the rows,
     append, remove by id, report a move to the index). F6b-3 combat and the actor panel depend
     on animals being ordinary actors.
   - `actors.json` gives the kind its components (`health` only): no needs, labour, skills,
     route or combat component, so the systems keyed on those components skip animals.
   - The kind is `"animal"`, separate from the incident `"wolf"` kind, so raids are unchanged.
3. **Phase.** `FaunaSystem.tick()` is registered as TickPipeline phase `"fauna"`. It walks the
   animal rows in table order (spawn order, ids ascend), and for each animal:
   - **Starving:** the animal dies once `starve_ticks` pass without a meal.
   - **Step tick:** otherwise it acts only on its step tick
     (`(tick + ordinal) % step_ticks == 0`). It eats if hungry and food is within reach:
     - a grazer eats from its own tile;
     - a predator eats prey within Chebyshev distance 1, and the prey dies.
   - **Moving:** if it did not eat, it moves one tile. A hungry predator moves toward the
     nearest prey in sight; any other animal moves to a random passable neighbour.
   - **Breeding:** it tries to breed. A fed adult whose interval has passed, with another adult
     of its species within the radius and the species under its cap, gives birth with
     probability `1 − count / cap`.

   The logistic chance is what holds a population at its cap instead of making it oscillate.
4. **Surface only.** Animals spawn, move and are checked at `z = TileGrid.SURFACE`.
5. **RNG.** `FaunaSystem` owns a `RandomNumberGenerator` seeded from
   `world seed + SEED_SALT`. The world's simulation stream is never drawn from; a test proves
   its state is unchanged with animals present.
6. **Worldgen.** `mapgen.animal_counts` (species → count, default empty) places animals on
   grass outside the spawn clearing, using the fauna stream. The same seed gives the same
   placement. `test_fauna_startup.gd` checks this through `WorldState.new()` itself.
   - **Shipped counts** (owner decision, round 1: the spawn is not deferred): grasshopper 12,
     bird 3, rabbit 6, deer 3, fox 1, wolf 1. Every new world therefore hashes differently, and
     the hash literals pinned by other tests are re-pinned in this change (listed in the F6b-1
     handoff).
7. **Persistence.**
   - Animals are saved in `entities` with kind `"animal"` and the extra fields `species`,
     `bornTick`, `lastMealTick` and `nextBirthTick`. `EntityValidator` checks that `species` is a
     species.json id of the session (`SaveIO.content_rules()["species"]`), the whole id matches
     `^animal_[0-9]+$`, `z` is `TileGrid.SURFACE` and the ticks are ints. Any other kind that
     carries one of those four fields is refused (review round 3). A save holding an unknown
     species, a malformed id or an underground animal is refused on read and on write.
   - Schema v15 also adds an optional top-level `fauna` field, `{nextAnimalId, rng: {seed,
     state}}`, checked by `FaunaValidator`. It carries no roster. The field is optional only
     while there are no animal entities. A save with animals must carry it, and `nextAnimalId`
     must exceed every saved `animal_<n>`; otherwise the next birth would reuse a live id
     (review round 2, `FaunaValidator._valid_fauna_for_animals()`).
   - `fauna.rng.state` is a full 64-bit integer, so `SaveJsonInts` restores it exactly, like
     the world's own stream. A float round trip above 2^53 would lose bits and diverge on the
     next draw.
   - The 14 → 15 migration adds nothing: a v14 save has no animal entities, and an absent
     `fauna` field means no animal was ever spawned.
   - The animals are hashed with the actor table. `state_hash()` adds the fauna counter and
     stream only once an animal has ever spawned, so an animal-free world (empty
     `animal_counts`) hashes exactly as before.
8. **Viewer.** `actor_sprites.gd` reads the snapshot's `animals` list. A species with pack art
   (the wolf) is drawn as a sprite like any other actor; the others are drawn as a
   species-coloured dot. Without the pack, nothing is drawn, as with every other actor.
9. **`world_state.gd`** wires the system through existing seams and stays at 767 lines.

## Alternatives considered

- **A separate animal roster inside `FaunaSystem`.** Proposed in the first draft to keep
  colonist-facing systems from ever seeing animals. Rejected by the owner in round 1: the design
  calls for one shared actor table with its own kind, which F6b-3 combat and the actor panel
  depend on. The A14 cost of sharing the table is measured below.
- **Deferring the shipped spawn counts.** Rejected by the owner in round 1: mapgen ships
  starting counts and a test spawns them through `WorldState` construction.
- **Logging bad species content and starting with no animals.** Rejected in review: a silent,
  empty ecosystem hides a content error. Bad content is now a fatal, typed startup error (§1).
- **Hard cap with a deterministic birth.** Rejected: the population overshoots and then
  saw-tooths at the cap. The logistic chance gives a smooth approach.
- **Drawing from the world RNG.** Rejected: adding one animal would change every later colonist
  decision, which breaks replay comparisons across content changes.

## Consequences

- **Performance.** Measured by `docs/orca/handoffs/F6b-1-bench.gd` (256×256 map, seed 42,
  1000 colonists, 60 ticks):
  - without animals: mean about 96 ms per tick (95.6 / 97.3 over two runs);
  - with the 26 shipped animals: about 95 ms (94.1 / 96.4), within noise;
  - with 200 animals in the shared table: about 106 ms (105.9 / 106.7);
  - the `"fauna"` phase alone: about 0.72 ms per tick.

  The shared table costs about 10 ms (about 11%) at 200 animals. Only about 0.7 ms of that is
  the fauna phase; the rest is the other phases walking a longer table and skipping the animal
  rows. With the separate roster of the first draft the difference was within noise. Every run
  is within the foundation-audit budget of 167 ms per tick, the limit for keeping up at ×3.
  None is under the 16 ms one-frame figure, which was already true without animals.
- **Rabbits** eat from `crop_tiles` without damaging the crops. The damage itself is F6b-2.
- **F6b-3** will reuse `health` and `attack` for hunting and combat.

## Acceptance criteria

- `test_fauna_population.gd`:
  - the grasshoppers reach the cap of 60 and hold it;
  - with 2 birds they peak below 60 and the birds survive;
  - the wolf is alive 10 ticks before `starve_ticks` and dead 10 ticks after.
- `test_fauna_species.gd`: content compiles and rejects bad input (including a mixed diet:
  a predator with `eats` or a grazer with `prey`); worldgen seeding works; the
  RNG stream is separate; shipped mapgen places animals.
- `test_fauna_persistence.gd`: the hash is deterministic, save/load continues identically, and
  a replay is ok. A real save file keeps a `fauna.rng.state` above 2^53 bit-exact, and a save
  with an unknown species is refused. So are animals without `fauna`, a `nextAnimalId` that is
  not past every animal id, an id off `^animal_[0-9]+$`, an animal off the surface, and a
  colonist carrying an animal field; a non-array `entities` is refused with `schema_error`.
- `test_content_registry.gd`: the shipped manifest lists exactly the content files, species.json
  included; a manifest entry naming a missing file, the manifest itself or a file twice fails
  construction with `missing_file`.
- `test_fauna_startup.gd`: bad prey or bad counts abort the real startup with the typed error;
  the shipped mapgen counts seed exactly those animals through `WorldState.new()`, as rows of the
  shared actor table, deterministically, outside the clearing, in `state_hash()` and in the view.
- `test_fauna_viewer.gd`: the wolf sprite, the placeholder dots, and dropping dead animals.
- `test_save_migration.gd`: the v14 → v15 migration and the v15 fixture.
