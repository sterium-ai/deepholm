# ADR 070: Wild species, animal actors and population dynamics

> **In short:** Six wild species are defined in `content/species.json` (grasshopper, bird, fox,
> rabbit, deer, wolf). Each species has a diet (a grazer eats tiles; a predator eats other
> species), a speed, a hunger time, a starvation window, an adult age, breeding rules and a
> population cap. Animals are actors of kind `"animal"` (faction `wildlife`) and live on the
> surface only. They are kept in their own roster in `FaunaSystem`, which runs once per tick in
> a new `"fauna"` TickPipeline phase. All of its random draws come from its own salted RNG
> stream. Births are logistic: once a breeding pair qualifies, a birth happens with probability
> `1 − count / cap`. Mapgen can seed starting counts; shipped content seeds none. Saves move to
> schema v14 (an optional `fauna` field). The viewer draws the wolf with the B3 pack art and
> the other species as coloured placeholder dots.

- **Status:** proposed (design closed with the owner in BACKLOG F6b, package 1 of 3 = F6b-1)
- **Date:** 2026-11-03
- **Scope:**
  - content: `species.json` and its schema, plus `mapgen.animal_counts`;
  - simulation: `FaunaSpecies`, `FaunaSystem`, `ActorTable.spawn_animal()`, the TickPipeline
    `"fauna"` phase;
  - persistence: schema v14 and `FaunaValidator`;
  - presentation: `actor_sprites.gd`.
- **Depends on:** ADR 066 (schema v13), the A9 view snapshot, B3 actor art, A14 tick budgets
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
2. **Actors.** An animal is a flat record with these fields: `id` (`animal_<n>`),
   `kind: "animal"`, `species`, `x`, `y`, `z`, `factionId: "wildlife"`, `bornTick`,
   `lastMealTick`, `nextBirthTick` and `health`.
   - `ActorTable.spawn_animal()` creates the record.
   - The records live in `FaunaSystem`'s own roster, not in the colonist and actor lists, so
     no labour, needs, job or combat system ever iterates over them.
   - The kind is `"animal"`, separate from the incident `"wolf"` kind, so raids are unchanged.
   - **Contract amendment, pending owner approval.** The F6b-1 backlog entry says "actors in the
     actor table". This decision keeps the record shape and the `ActorTable` factory but not
     the shared list. Moving the records into the shared list would make every colonist-facing
     system and its tests filter on `kind`, including systems outside F6b-1's owned paths.
     If the owner rejects the amendment, the integration becomes its own task.
3. **Phase.** `FaunaSystem.tick()` is registered as TickPipeline phase `"fauna"`. It walks the
   roster in spawn order (ids ascend), and for each animal:
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
   - **Shipped counts are deferred, pending owner approval.** Adding counts to the shipped
     `mapgen.json` was measured: it changes `state_hash()` for every new world. Two pinned
     literals in `test_toils_dig_chop_regression.gd`, which is outside F6b-1's owned paths,
     then fail: `EXPECTED_HASH` goes from 3133873738 to 3745611256, and
     `COLONY_EXPECTED_HASH` from 2587936448 to 3592413806. The owner either approves
     re-pinning those literals, or ships counts in a later balance task.
7. **Persistence.**
   - Schema v14 adds an optional top-level `fauna` field: `{animals, nextAnimalId, rng: {seed,
     state}}`.
   - `FaunaValidator` checks it. An animal's `species` must be a species.json id of the session
     (`SaveIO.content_rules()["species"]`); a save holding an unknown species is refused on read
     and on write.
   - `fauna.rng.state` is a full 64-bit integer, so `SaveJsonInts` restores it exactly, like
     the world's own stream. A float round trip above 2^53 would lose bits and diverge on the
     next draw.
   - The 13 → 14 migration adds nothing, because an absent field means no animals.
   - `state_hash()` includes the fauna block only once an animal has ever spawned, so animal-free
     worlds hash exactly as before.
8. **Viewer.** `actor_sprites.gd` reads the snapshot's `animals` list. A species with pack art
   (the wolf) is drawn as a sprite like any other actor; the others are drawn as a
   species-coloured dot. Without the pack, nothing is drawn, as with every other actor.
9. **`world_state.gd`** wires the system through existing seams and stays at 767 lines.

## Alternatives considered

- **Animals in the shared actor list.** Rejected, pending the owner's approval of the amendment
  in §2: every colonist-facing system would have to filter them out, and the A14 cost would grow
  with every system.
- **Logging bad species content and starting with no animals.** Rejected in review: a silent,
  empty ecosystem hides a content error. Bad content is now a fatal, typed startup error (§1).
- **Hard cap with a deterministic birth.** Rejected: the population overshoots and then
  saw-tooths at the cap. The logistic chance gives a smooth approach.
- **Drawing from the world RNG.** Rejected: adding one animal would change every later colonist
  decision, which breaks replay comparisons across content changes.

## Consequences

- **Performance.** Measured by `docs/orca/handoffs/F6b-1-bench.gd` (256×256 map, seed 42,
  1000 colonists, 60 ticks):
  - without animals: mean 75.8 ms per tick;
  - with 200 animals: mean 74.7 ms per tick (the difference is noise);
  - the `"fauna"` phase alone: 0.33 ms per tick.

  Both runs are within the foundation-audit budget of 167 ms per tick, the limit for keeping up
  at ×3. Neither is under the 16 ms one-frame figure, but the animals add nothing measurable to
  that.
- **Rabbits** eat from `crop_tiles` without damaging the crops. The damage itself is F6b-2.
- **F6b-3** will reuse `health` and `attack` for hunting and combat.

## Acceptance criteria

- `test_fauna_population.gd`:
  - the grasshoppers reach the cap of 60 and hold it;
  - with 2 birds they peak below 60 and the birds survive;
  - the wolf is alive 10 ticks before `starve_ticks` and dead 10 ticks after.
- `test_fauna_species.gd`: content compiles and rejects bad input; worldgen seeding works; the
  RNG stream is separate.
- `test_fauna_persistence.gd`: the hash is deterministic, save/load continues identically, and
  a replay is ok. A real save file keeps a `fauna.rng.state` above 2^53 bit-exact, and a save
  with an unknown species is refused.
- `test_fauna_startup.gd`: bad prey or bad counts abort the real startup with the typed error;
  mapgen counts seed animals through `WorldState.new()`, deterministically and outside the
  clearing.
- `test_fauna_viewer.gd`: the wolf sprite, the placeholder dots, and dropping dead animals.
- `test_save_migration.gd`: the v13 → v14 migration and the v14 fixture.
