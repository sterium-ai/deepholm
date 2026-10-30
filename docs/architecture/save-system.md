# Save system

> **In short:** How the game saves and loads: several rotating save files, writes that can never leave a half-written file behind, and a versioned format that refuses saves it cannot read instead of guessing.

This page documents the implemented persistence contract for the game. Save
I/O is outside the authoritative simulation; snapshots are versioned,
validated, and replaced only after a complete candidate has been written.

## Files and slot rotation

The default directory is `user://saves` (the manager allows an injected
directory for tests). It contains these slots:

```text
user://saves/
  manual.json
  autosave-1.json
  autosave-2.json
  autosave-3.json
```

`manual.json` is written only by a manual save; autosaves never evict it.
Each autosave overwrites the slot with the oldest recorded `(epoch, tick)`
pair (see "Game sessions and New Game"); a missing or unreadable file counts
as oldest. So the order is oldest-slot-first, not round-robin: four saves at
one epoch leave saves 2, 3 and 4 in the three autosave files. Selection reads
the epoch/tick stored in each file, never file modification time, so it
survives a process restart.

`load_best()` considers all four existing files in descending `(epoch, tick)`
order and validates them until one succeeds. Rejected candidates, including a
pre-release save (see "Schema version, pre-release saves and migration"
below), are returned in `skipped`, in trial order, with their typed error code
and message.

## Last-known-good save

The manager's last-known-good pointer is in memory, initially null. After a
candidate is independently validated by a successful write or `load_best()`,
it records `{slot, file, epoch, tick}`. It advances only for a strictly newer
`(epoch, tick)` pair, never points at a failed candidate, and is not a
separate persisted pointer file.

## Game sessions and New Game

`epoch` is a top-level integer field on every save (`StateCodec.encode()`
always emits `0`; `SaveManager.save_manual()`/`save_autosave()` overwrite it
with a caller-supplied value before writing). It is a `SaveManager`/boot.gd
session marker, not `WorldState` state: `StateCodec.decode()` ignores it when
restoring a world. Ordinary continuing play (an existing game ticking forward,
an ordinary Load) keeps whatever epoch the loaded save carried; `tick` alone
orders recency within one epoch.

boot.gd's New Game control mints a strictly higher epoch via
`SaveManager.next_epoch()` (`1 + highest_known_epoch()` across all four
slots, maxed against boot.gd's own in-memory `_current_epoch` so it is also
newer than the game currently live). Every save/load candidate is ordered by
`(epoch, tick)` lexicographically, so a freshly started, low-tick game's
manual save outranks an older game's high-tick autosave (an old colony's
autosave at tick 1000 would otherwise outrank a new game saved at tick 10).

New Game also suspends `AutosaveTrigger` (`set_enabled(false)`) right after
replacing the world, so an unsaved new game cannot evict an autosave of the
game it replaced -- the New Game dialog promises the previous save is kept
until Save is pressed. The first successful manual Save (`_on_save_pressed()`)
re-enables it, and so does loading a save (`_replace_world()`).

## Atomic writes and errors

`SaveIO.write_atomic()` validates the state, packs it (`SaveWire.pack()`, see "Wire
encoding" below) and stringifies it once, hashes that text once, writes the envelope
around it to `<target>.tmp`, flushes and closes it, reads the temporary file back, and
verifies its integrity and schema before one rename replaces the target. Any
failure removes the temporary file and leaves the previous target intact.

**Off the main thread (A7, [ADR 058](../decisions/058-save-pipeline-wire-encoding.md)).**
`SaveIO.begin_write()` does only the pack and the one `JSON.stringify` on the calling thread
and returns a `SaveWrite` handle; hashing, the temporary write, the read-back (the same checks
as `read()`, which is also where a state that does not validate is refused before the target
changes) and the rename run on the handle's `Thread`. The worker gets the text, the path and
`SaveIO.content_check()`'s plain copy of the session registry's version, packs and whitelists:
never the state Dictionary or the world, so the world may tick on as soon as `begin_write()`
returns. `SaveWrite.wait()` joins and returns the `write_atomic()` result; `is_done()` polls.
`SaveManager.begin_save_manual()`/`begin_save_autosave()` encode the world and call it, and
advance the last-known-good pointer inside `wait()`; `save_manual()`/`save_autosave()` are the
same followed by `wait()`. A manager runs one write at a time (a new save or `load_best()`
waits for the one in flight). `boot.gd` and `AutosaveTrigger` still call the blocking form;
polling the handle from the viewer is a follow-up (see `docs/orca/handoffs/A7.md`).

The typed result codes are:

- `write_failed` — temporary file could not be opened or flushed/closed.
- `write_interrupted` — writing was interrupted before replacement.
- `rename_failed` — the atomic replacement rename failed.
- `read_failed` — a save could not be opened.
- `parse_error` — JSON is malformed or truncated.
- `unsupported_pre_release_save` — the envelope format is the pre-release
  `"deepholm-save-v1"`; the save is never migrated (see below).
- `invalid_envelope` — the format, integrity field, or state envelope is absent or invalid.
- `integrity_mismatch` — the stored state hash does not match.
- `schema_error` — the state shape, type, range, enum, or current schema is invalid.
- `no_migration_available` — `schemaVersion` is missing, or the save is older
  than the current schema and no migration step covers it.
- `save_from_newer_version` — the save was produced by a newer schema than this build.
- `content_version_mismatch` — the save's `contentVersion` does not match the session's
  content bundle and no registered content rename resolves it (see "Schema version,
  pre-release saves and migration" below).
- `content_packs_mismatch` — the save's `contentPacks` is not exactly the session's
  `ContentRegistry.packs()`; `reason` is `missing`, `version`, `unexpected` or `order` (see
  "Content packs" below).

## Schema version, pre-release saves and migration

A save file is the envelope `{format: "deepholm-save", integrity, state}`
(`SaveIO.FORMAT`), where `integrity` is the SHA-256 of the state's JSON text exactly as
written (A7; `read()` hashes the raw `state` span, and falls back to the pre-A7 rule, the
SHA-256 of `JSON.stringify` of the parsed state, for files written that way).
The state carries `schemaVersion: 8` (`StateCodec.SCHEMA_VERSION`) and, once unpacked, is
described field for field by
[`contracts/game-state.schema.json`](contracts/game-state.schema.json). The
schema was reset to v1 before the first public release (see
[ADR 049](../decisions/049-save-schema-reset-v1.md)); v2 stops saving terminal
jobs (see "Jobs" below and [ADR 053](../decisions/053-job-storage-retired-history.md));
v3 records the content packs the save was made on (see "Content packs" below and
[ADR 010](../decisions/010-content-registry.md), amendment 2); v4 saves the
scenario's calendar and incident list (see "Scenario start" below and
[ADR 057](../decisions/057-scenario-start-fields.md)); v5 writes the compact wire
encoding and saves each in-flight route search's accumulated costs (see "Wire encoding" and
"Route searches" below and [ADR 058](../decisions/058-save-pipeline-wire-encoding.md)); v6 adds
farm zones and the crop growth records (see "Crops" below and
[ADR 059](../decisions/059-crops-and-farm-zones.md)); v7 saves the workbench targets, orders and
bills (see "Workbenches" below and [ADR 061](../decisions/061-workbench-recipes-and-craft-labour.md)); v8 saves every
colonist's skills (see "Colonist needs, the labour table and skills" below and
[ADR 062](../decisions/062-skills-and-xp-per-labour.md));
v9 lets a stockpile carry its item-group filter and priority (see "Stockpile zones" below and
[ADR 064](../decisions/064-stockpile-filters-and-priorities.md)).

**Wire encoding.** `persistence/save_wire.gd` packs the state right before the one
`JSON.stringify` of a write and unpacks it right after the parse of a read (after the
integer coercion, before migration and validation), so `StateCodec`, the validators and the
JSON Schema all see the plain state. Packed:

- `map.tiles` becomes `map.palette` (tile ids in first-appearance order) and `map.tileRuns`
  (flat `[paletteIndex, runLength, ...]`, row-major).
- A route search (`entities[].route.rerouting`, `scheduling.pending.*.route`) replaces
  `visited`, `cameFrom`, `cost` and `frontier` with `box` (`[x, y, width, height]` around the
  visited tiles), `visitedBits` (bitset over the box, row-major), `cameFromDirs` (2 bits per
  visited tile in that order: the direction to its parent, `RouteSearch.NEIGHBOR_OFFSETS`'
  index; the start's bits are 0 and unused), `costBytes` (one float64 per visited tile in that
  order) and `frontierTiles` (int32 map tile indices in frontier order), all base64.
- `entities`, `jobs`, `crops` (v6) and `scheduling.waiting` become a record table: a first element
  `{"$keys": [sorted keys]}`, then one row of values per record.

The packer only packs what comes back exactly: a list of fewer than two records, a record with
other keys than the first one (kept as a plain object in the table), a route whose `cameFrom`
is not one adjacent parent per visited tile, or a tile off the map stay plain, and the reader
accepts the plain form of any of these fields. After a load the visited tiles of a search are
in row-major order instead of discovery order; nothing depends on that order.

**Crops.** A zone with `"kind": "farm"` carries its `crop` (a `crops.json` id); a stockpile
carries neither. `crops` lists `FarmSystem`'s growth record of every sown tile,
`[{target, crop, growth}]` in tile-key order, both validated against the session's crop ids.
`FarmSystem.decode()` reconciles the records with the decoded tiles, so a sown tile always
has one and nothing else does.

**Content packs.** `contentPacks` is the saving world's `ContentRegistry.packs()` in load
order, `[{id, version}]`, empty on the base bundle. `SaveIO.read()` and `write_atomic()` take
the session registry (null builds the base bundle); `SaveManager` holds it from construction
(`boot.gd` passes `session_content()`) and `SaveWiring.load_best()` decodes on it. A save loads
only when its list equals the session's exactly, same versions in the same order; otherwise it
is rejected with `content_packs_mismatch` and never repaired onto other packs. The tile, job
and need whitelists and the map size cap are read from the same registry
(`SaveIO.content_rules()`), so a pack's ids are valid in a save made on that pack.

**Jobs.** `jobs` lists the open (queued or active) jobs only, in submission
order. A completed, failed or cancelled job leaves `JobQueue`'s live list at
once and is kept only in its bounded, unsaved history (`jobs/job_history.gd`,
the last 256), so neither the save nor `state_hash()` grows with play time. A
loaded world starts with an empty history: a command naming a job finished
before the load is rejected as `unknown_job`. The validator still accepts the
five statuses, and `JobQueue.restore()` retires a terminal entry it is given.

**Pre-release saves.** Saves written by development builds before the reset
use the envelope format `"deepholm-save-v1"` (`SaveIO.PRE_RELEASE_FORMAT`)
with an old-chain `schemaVersion` of 1 to 27. `SaveIO.read()` recognises that
format before anything else and rejects the file with
`unsupported_pre_release_save` and a message starting "unsupported pre-release
save" that tells the player to start a new game. Such a save is never
migrated, and `SaveManager.load_best()` reports it as skipped while it keeps
looking for a loadable slot.

**Read order.** `SaveIO._read_and_verify()` rejects a pre-release or
malformed envelope, then a newer `schemaVersion` (before the integrity hash,
so a newer producer always gets `save_from_newer_version`), then checks the
integrity hash, restores exact 64-bit integers (see "Seed fidelity"),
migrates an older `schemaVersion`, resolves a content rename if needed, checks
`contentPacks` against the session's packs, and runs `_validate_state()`. A rejected save's state is never returned.

**Migration chain.** `SaveMigrations.migrate()`
(`game/scripts/core/persistence/save_migrations.gd`) chains single-version
`_migrate_step()` calls from the save's version to the current one. Each step
returns a new dictionary and never mutates its input. Steps today:

- **v1 → v2** (A5, ADR 053): drops every completed/failed/cancelled entry from
  `jobs`; nothing else changes. `save_schema_v1_fixture.json` migrates exactly
  to `save_schema_v2_fixture.json` (the same session written at v2).
- **v2 → v3** (A13b, ADR 010 amendment 2): inserts `contentPacks: []` after
  `contentVersion` (no v2 build loaded packs into a save session). The v1 and v2
  fixtures both migrate exactly to `save_schema_v3_fixture.json`.
- **v3 → v4** (A16b, ADR 057): adds `scenarioStart` as the base start,
  `{"calendar": null, "enabledIncidents": []}` (a v3 world always ran on
  `calendar.json` and every incident); nothing else changes, and a v3 state that
  already has the field is refused. The v1, v2 and v3 fixtures all migrate exactly
  to `save_schema_v4_fixture.json` (the same session written at v4,
  `docs/orca/handoffs/A16b-write-save.gd`).
- **v4 → v5** (A7, ADR 058): the unpacked shape is unchanged; a v4 route search has no
  `cost`, which stays absent, so `RouteSearch.restore()` rebuilds its costs from the current
  map exactly as every v4 load did. The v1 to v4 fixtures all migrate exactly to
  `save_schema_v5_fixture.json` (the same session, written packed by
  `docs/orca/handoffs/A7-write-save.gd`).
- **v5 → v6** (F1, ADR 059): adds `crops: []`; every v5 zone is already v6's stockpile
  shape. A sown tile of a v5 save gets its record on decode, at its stage's threshold. The
  v1 to v5 fixtures all migrate exactly to `save_schema_v6_fixture.json` (the same session,
  written packed by `docs/orca/handoffs/F1-write-save.gd`).
- **v6 → v7** (F2, ADR 061): adds `crafting` with no configured bench,
  `{"benches": [], "nextOrderId": 1}` (a v6 world had no recipes); nothing else changes, and a
  v6 state that already has the field is refused. The v1 to v6 fixtures all migrate exactly to
  `save_schema_v7_fixture.json` (the same session, written packed by
  `docs/orca/handoffs/F2-write-save.gd`).
- **v7 → v8** (F3, ADR 062): every colonist entity gains `skills`, each labour of its
  `labourTable` at `{level: 0, xp: 0}` (starting skills are seeded only when a world is
  created); nothing else changes, and a v7 colonist that already has the field is refused.
  The v1 to v7 fixtures all migrate exactly to the v7 fixture's session with those zero
  skills; `save_schema_v8_fixture.json` is the same session written by this build
  (`docs/orca/handoffs/F3-write-save.gd`), whose colonists have seeded skills and so work at
  other speeds: it loads and re-encodes unchanged.
- **v8 → v9** (F5a, ADR 064): the unpacked shape is unchanged; a v8 stockpile accepted every
  item at one priority, which is a v9 stockpile with neither optional key. A v8 zone that
  already carries `groups` or `priority` is refused. `save_schema_v8_fixture.json` migrates
  exactly to `save_schema_v9_fixture.json` (the same session, written packed by
  `docs/orca/handoffs/F5a-write-save.gd`).

A version with no arm (below 1) is rejected with `no_migration_available`;
nothing is ever silently filled from current defaults. Adding schema version
N+1 (the recipe in the class doc):

1. Bump `StateCodec.SCHEMA_VERSION`.
2. Add an `N:` arm to `_migrate_step()` that checks the vN shape and returns
   the vN+1 state.
3. Add `game/scripts/tests/fixtures/save_schema_vN+1_fixture.json`.
4. Add a test that the vN fixture loads through `SaveIO.read()` as vN+1.

**Content renames.** Every save records `contentVersion` (the saving world's
`ContentRegistry.version()`, `content/manifest.json`'s `version`), and
`_read_and_verify()` compares it to the session registry's. A mismatch gets one chance through a remap registered for
the save's exact stored `contentVersion`
(`SaveMigrations.register_content_rename()`/`unregister_content_rename()`/
`resolve_content_version()`); the remap returns a new state with renamed
content ids and the resolved `contentVersion`, which is then validated like
any other state. Without a registered remap the save is rejected with
`content_version_mismatch`. Nothing is registered today. A rename is only
attempted when the stored `contentVersion` is a `String`; a missing or
wrong-typed one is left for `_validate_state()` to report.

**Validation.** `SaveIO._validate_state()` mirrors the JSON Schema. It first
checks the top-level keys: `TOP_LEVEL_FIELDS` must all be present,
`OPTIONAL_TOP_LEVEL_FIELDS` may be present, and anything else is rejected as an
unexpected field. It then checks `schemaVersion`, `contentVersion`, `contentPacks`, `seed`,
`tick`, `epoch` and `map`, and calls one validator per persisting module under
`game/scripts/core/persistence/validators/`, in a fixed order so the first
reported error is stable: `map_validator.gd`, `item_validator.gd`,
`object_validator.gd`, `farm_validator.gd`, `work_progress_validator.gd`, `giver_validator.gd`,
`calendar_validator.gd`, `tool_validator.gd`, `entity_validator.gd` and
`scheduling_validator.gd`, with shared helpers in `save_check.gd`. An optional
field is validated only when present.

**Encoding.** `persistence/state_codec.gd` owns `encode()`/`decode()` plus
objects, items, zones, ground berries, work progress, tool items and
construction sites; `entity_codec.gd` encodes entities and components,
`scheduling_codec.gd` jobs and scheduler state, and `giver_codec.gd` the
rescue/combat/approach associations, calendar alerts, tool-fetch exclusions
and incident scheduler.

**Optional fields.** `encode()` always writes every top-level field. The
fields in `OPTIONAL_TOP_LEVEL_FIELDS` (`combatBlockedTargets`, `digFindRng`,
`rescueVictimAssignments`, `workProgressOwners`, `suspendedWorkProgress`,
`approachJobTargets`, `constructionSites`, `areaOrders`) are optional on read:
an absent one decodes as the empty or default value (no sites, no owners, a
fresh dig-find stream, and so on).

**Fixtures and tests.** `game/scripts/tests/fixtures/save_schema_v1_fixture.json`
is a v1 save and `pre_release_save_v27.json` a real save written before the
reset; `game/scripts/tests/test_save_migration.gd` covers both, the empty
chain, content renames and the optional fields. `test_save_route_continuation.gd` covers
the saved route costs (see "Route searches"); `test_farm_zone.gd` saves and reloads a world
mid-growth.

**Route searches.** A route state (`rerouting`, `scheduling.pending.*.route`) is
`{start, target, status, frontier, visited, cameFrom, cost?, path, expansions, resumeCalls}`;
`cost` (v5) is the accumulated cost of each `visited` tile, in `visited` order. A search can
span a map change, so `RouteSearch.restore()` takes these costs as they were instead of
recomputing them from the current map (which reordered the frontier, A0 audit §4.4); only a
state without `cost` (a migrated v4 save) is rebuilt. `state_hash()` covers the costs.

## World dimensions and generation

Every save's `map` field is `{width, height, tiles, generatorVersion}`. A
world's dimensions are fixed for its lifetime. A new world's requested size is
clamped by `WorldGenerator.resolve_size()` into `mapgen.json`'s
`min_world_size`/`max_world_size`; a restored save keeps its own
`map.width`/`map.height` exactly, never re-clamped (a 3x2 test fixture decodes
at 3x2). Loading a save replaces the whole `WorldState` instance.
`WorldState.MAP_WIDTH`/`MAP_HEIGHT` (48x48) are the constructor defaults used
by fixtures and tests; boot.gd's New Game passes `mapgen.json`'s
`default_new_game_width`/`default_new_game_height` (256x256).

Terrain is generated once by `WorldGenerator`
(`game/scripts/core/worldgen/world_generator.gd`) and never regenerated on
load: `tiles` is restored exactly as stored. `map.generatorVersion` records
the algorithm that produced the stored terrain: a fresh world gets the running
build's `WorldGenerator.GENERATOR_VERSION`, a loaded world keeps the save's
value, so re-saving never relabels it. It is diagnostic only and never checked
on load. Mapgen count/placement budgets scale with the map area relative to
`reference_width*reference_height` (48x48). See
[ADR 019](../decisions/019-world-dimensions-and-generation.md).

`_validate_state()` rejects a `tiles` array whose length is not
`width*height` and a `map.width`/`map.height` above `max_world_size`, and
bounds-checks every persisted tile coordinate in the save against the map's
declared size: entity, item, object, construction-site, zone, area-order,
tool-item, job, queue-entry, route (including nested `start`/`target`/
`frontier`/`visited`/`cameFrom`/`path`), ground-berry, work-progress and
giver-association positions.

## Seed fidelity

The top-level `seed`, `rng`, `incidentScheduler.rng` and `digFindRng`
seed/state values are GDScript 64-bit integers (the full range boot.gd's New
Game seed field accepts). `JSON.parse_string()` decodes every number as a
64-bit float, which would silently round a value at or beyond 2^53, so
`persistence/save_json_ints.gd` (`SaveJsonInts`) re-reads them from the raw
wire text. `_locate_state_object()` structurally walks the envelope to the
top-level `"state"` member and records the text span of each of its direct
members; `_restore_exact_seed()`, `_restore_exact_rng()`,
`_restore_exact_incident_rng()` and `_restore_exact_dig_find_rng()` read each
field's token from that span. The walk is a minimal hand-written JSON scanner,
not a regex: it never confuses `state`'s own `seed` with a same-named key
elsewhere in the envelope, and it decodes keys spelled with a `\uXXXX`
escape (e.g. `"\u0073eed"`). If a field the parsed Variant says exists cannot
be located, `SaveIO.read()` fails closed with `schema_error`.

`_parse_json_integer_token()` decomposes the complete number token. A whole
number restores exactly however it is spelled (`1000`, `1e3`, `1.000e3`); a
fractional value or a magnitude outside the signed 64-bit range is a
`schema_error`, never truncated. The exponent is bounds-checked before any
conversion or zero-padding, so `1e999999999999999999999999` is rejected
immediately (a zero mantissa still gives `0`). Every other integer field goes
through `SaveJsonInts._coerce_floats_to_ints()`, since the schema declares no
floating-point fields.

## Entities, faction membership and health

`entities` is an array of actor records. Every entity carries `id`, `kind`
(`colonist`, `wolf` or `trader`), `x`, `y`, `factionId`, `health`, `route`
and `trapped`, plus the component fields its kind declares
(`EntityValidator.ENTITY_COMPONENT_FIELDS`, the schema's per-kind if/then):

- `colonist`: `needs`, `needsAccumulator`, `labourTable`, `work`, `hands`,
  and optionally `heldTool`;
- `wolf`: `needs`, `needsAccumulator`, `combat`, `wild: true`;
- `trader`: `inventory` (`{items, tool, capacity}`), `visitor: true`.

`EntityCodec` writes a component field only when the live actor carries it,
never as a colonist-shaped default, and decodes an absent one as absent.

`factionId` (a lowercase id, `^[a-z0-9_-]+$`) names the faction the entity
belongs to; every colonist today belongs to `"colony"`. `health` is
`{hp, maxHp, dead}`, the health component's per-instance state (`ActorHealth`,
[ADR 012](../decisions/012-actors-and-components.md)), so a colonist's actual
hp survives a save/load round trip. `CombatSystem.ensure_health()` backfills
`factionId: "colony"`, `trapped: null` and a full-health component onto any
live actor missing them (a hand-built test fixture or a colonist spawned this
session). `combat` is `{attack, damage, cooldown, cooldownRemaining}`.

`route` is `null` or `{jobId, path, step, moveTicksRemaining, rerouting?}`;
`rerouting` is present only while a re-route search is in flight. `work` is
`null` or `{jobId, ticksRemaining}`. `trapped` is `null` or
`{tile, ticksRemaining?, fromTile?}` for an actor caught in a trench
([ADR 026](../decisions/026-trench-trapped-actor-and-rescue.md)).

## Object, item and ground-berry faction ownership

Every persisted object and item entry has a required `factionId` (same id
pattern), the persisted counterpart of the `faction_id` field
`WorldState.get_objects()`/`get_items()` expose. Ownership lives in parallel
maps keyed like the objects/items themselves (`ObjectTable.object_factions`,
`ItemTable`'s item factions); the encoders read them (defaulting an untracked
entry to `"colony"`) and the decoders restore them.

`groundBerries` is an array of `{target, berries, factionId}` per-tile
counters (not first-class items). `ItemTable` keeps the faction in its
`ground_berries_factions` map, `StateCodec._encode_ground_berries()` writes it
(defaulting to `"colony"`) and `_decode_ground_berries()` restores it, so
`WorldState.get_ground_berries_faction_id()` reads the same value after a
load ([ADR 047](../decisions/047-work-progress-owner-records-and-ground-berry-factions.md)).
`state_hash()` covers the berry counts; the faction maps stay out of the
hash.

## Tile objects

The top-level `objects` array holds one entry per *placed* object
([ADR 005](../decisions/005-tile-objects-schema-v4.md), revised by
[ADR 039](../decisions/039-object-footprint-rotation.md)):
`{target: {x, y}, kind, factionId, orientation?, health?}`. `target` is the
object's origin tile; `kind` names an entry in `game/content/objects.json`
(for example `chair`, `door`, `wooden_wall`, `workbench`).

- `orientation` is `"horizontal"`, `"vertical"` or `""`, meaningful only for
  a kind that declares `rotatable: true` (e.g. `workbench`). The encoder writes it only for a
  non-default orientation; absent and `""` both mean no rotation and decode
  identically.
- `health` is `{hp, maxHp}`, written only for an object whose kind declares
  `max_health` (e.g. `wooden_wall`, `door`), so a damaged wall keeps its exact
  hp across a save/load round trip. When absent for such a kind,
  `ObjectTable.ensure_object_health()` backfills the content default.
  `state_hash()` includes object health, since it changes future combat
  outcomes.

A kind whose content `footprint` is larger than `[1, 1]` occupies every tile
of that footprint (`[w, h]` swapped under `"vertical"`) with the same
kind/faction/health, but persists as exactly one entry naming its origin:
`ObjectTable.object_footprint_tiles()` re-expands it to every occupied tile on
`decode()`. `WorldState` reads this state through `get_object(x, y) -> String`
(`""` for an empty tile; the same kind at every footprint tile) and
`get_objects() -> Array[Dictionary]` (detached `{x, y, kind, faction_id}`
copies, one per occupied tile). `state_hash()` covers the per-tile objects
map, so adding, removing or rotating an object changes the hash.

## Construction sites

The optional top-level `constructionSites` array holds one record per active
construction site ([ADR 040](../decisions/040-construction-sites.md)):
`{id, kind, origin, orientation, requiredMaterials, heldMaterials, progress,
buildTicks, maxBuilders, builderIds}`. `kind` is the `objects.json` id the
site will place at `origin` (orientation as for objects, here always written);
`requiredMaterials`/`heldMaterials` are `{item, quantity}` lists; `progress`
counts work ticks done towards `buildTicks` (>= 1); `builderIds` lists the
colonists assigned to it, at most `maxBuilders` as the giver assigns them. The
site id counter is not persisted: decode re-derives it from the highest
`site_<N>` id present. `state_hash()` hashes the site list directly, so states that differ
only in held materials, progress or builders never hash equal. See
[orders-and-movement.md](orders-and-movement.md)'s "Construction" section for
how sites are worked.

## Workbenches

The optional top-level `crafting` object (schema v7, [ADR 061](../decisions/061-workbench-recipes-and-craft-labour.md))
is `{benches, nextOrderId}`. Each bench record is `{x, y, targets, orders, bill}`: `x, y` is
the workbench's origin tile, `targets` the `[{recipe, count}]` "keep N in stock" list (count
1..999, sorted by recipe), `orders` the queue `[{id, recipe, remaining}]` in order, and `bill`
either `null` or `{recipe, orderId, held}`: the recipe being made, the order it serves (`""`
for a target) and the inputs already delivered, `[{item, quantity}]`. `nextOrderId` continues
the `order_<n>` ids. Absent (and every v6 save, migrated to `{benches: [], nextOrderId: 1}`)
means no configured bench. A bench whose object is gone is dropped on the next tick. The
craft jobs themselves are ordinary saved jobs (`craft_fetch` with its bench origin in `site`,
`craft_work` with its progress in `workProgress`); a delivering craft_fetch's route resumes
with the bench's target-tile exception. `state_hash()` covers `crafting` once any bench was
configured.

## Items and hands

The top-level `items` field is `{nextId, list}`. Each `list` entry is a
first-class ground item, `{id, x, y, kind, count, factionId}` (for example
`kind: "wood"` or `"stone"`); `nextId` is the next never-yet-used item id,
persisted so a restored world never reuses an id. `WorldState` exposes items
through `get_items() -> Array[Dictionary]` (id-sorted, detached
`{id, x, y, kind, count, faction_id}` copies) and the derived
`get_ground_wood(x, y) -> int` (the sum of every wood item's `count` at that
tile). A chop job's completion creates one wood item with a fresh id
(`ItemTable.spawn_item()`, with the work effect from `jobs.json`, ADR 051).

A colonist's `hands` field ([ADR 037](../decisions/037-hands-multi-unit-carrying.md))
is an array of `{kind, count}` entries, one per distinct kind held,
every `count >= 1`, with the sum of counts never exceeding 4
(`ActorInventory.HANDS_CAPACITY`) plus one per 5 levels of the colonist's `haul` skill
(`skills.json` `carry_labour`/`carry_bonus_every`, ADR 062). A `hands` entry carries no item id and no
ground position: a `pick_up` may merge units from several ground items of the
same kind into one entry, and `place()` mints a fresh ground item id per entry
it deposits (the toils are described in
[orders-and-movement.md](orders-and-movement.md)'s "Jobs, toils and
reservations" section).

`state_hash()` covers both the items and the next item id, since two states
with the same items but different counters hand out different ids on the
next chop.

## Stockpile zones

The top-level `zones` field is an array of `{id, x, y, width, height}`
rectangles, each a player-drawn stockpile area (`zone_add`/`zone_remove`
commands, see [orders-and-movement.md](orders-and-movement.md)'s "Zone
commands" section); `nextZoneId` is the next never-yet-used zone id, persisted
for the same reason as `items.nextId`. `WorldState` exposes zones through
`get_zones() -> Array[Dictionary]` (id-sorted, detached copies) and
`get_zone(id) -> Dictionary` (`{}` for an unknown id). `state_hash()` covers
the zones and the next-id counter.

Since v9 ([ADR 064](../decisions/064-stockpile-filters-and-priorities.md)) a stockpile may also
carry `groups`, the ascending list of item groups it accepts (an item's group is its
`items.json` `kind`; SaveIO accepts only the session's kinds), and `priority`, 1 to 3. Each key
is written only when set away from its default (every group, priority 2), so a stockpile nobody
configured is the v8 record byte for byte. A farm zone never carries either. The
`zone_set_stockpile` command sets both.

## Area orders

The optional top-level `areaOrders` field
([ADR 044](../decisions/044-area-order-expansion-queue.md)) is
`{nextId, list, created}`. `nextId` is the next order id. `list` holds one
entry per pending `area_order` expansion, in acceptance order:
`{id, order, actor, commandId, x, y, width, height, priority, next, done,
jobLimit, siteLimit}`, where `next` is the row-major index of the next tile to
expand and `done` the indexes from `next` on already expanded early for a
later order over the same tile (so a save taken mid-expansion resumes exactly
there), and `jobLimit`/`siteLimit` are the next job/site number when the order
was accepted. `created` lists `[first, end, order id]` ranges of job numbers
an area order created while a later cancel was pending (that cancel may pick
them although they are newer than its `jobLimit`).
`ObjectValidator._valid_area_orders()` checks the shape, a known `order`, an
in-map non-empty rectangle, `0 <= next < width*height`, distinct `done`
indexes in `[next, width*height)`, and ascending, disjoint `created` ranges
naming a past order id. `state_hash()` covers it while an order is pending.

## Job fields

Every persisted job entry is `{id, kind, status, priority, target, reason,
remedy, blockingJobId, itemId, cell, retryAt, backoffTicks, site?}`
(`SchedulingCodec._encode_jobs()`). `kind` is one of `dig`, `site_fetch`,
`site_work`, `craft`, `chop`, `haul`, `forage`, `till`, `sow`, `mine`,
`eat_food`, `drink_water`, `sleep`, `incident`, `escape_trench`, `flee`,
`rescue`, `approach`.

- `itemId` (the ground item a hauling job carries, `""` otherwise), `cell`
  (its reserved destination `{x, y}`, or `null`) and `retryAt`/`backoffTicks`
  (the doubling-backoff retry state used when no destination is free, see
  [orders-and-movement.md](orders-and-movement.md)'s "Haul backoff" section)
  are always present, with harmless defaults (`""`, `null`, `0`, `0`) on jobs
  that do not use them.
- `site` is the origin tile of the construction site a `site_fetch` or
  `site_work` job serves, or `null`. It is always written and optional on
  read (absent means `null`); `SchedulingValidator._valid_jobs()` bounds-checks
  it and requires it to be non-null for `site_fetch`/`site_work`. The kind to
  build is not on the job: it lives on the site record in
  `constructionSites`.

All job fields, `site` included, reach `state_hash()`'s `"jobs"` entry through
`get_jobs()`, so jobs serving different sites hash differently.

## Colonist needs, the labour table and skills

A colonist's (and a wolf's) `needs` field is `{food, water, rest}`, every
value an integer 0-100 that decays at its content-declared rate
(`content/needs.json`) and is restored by that need's job kind
(`eat_food`/`drink_water`/`sleep`, see
[orders-and-movement.md](orders-and-movement.md)'s "Need jobs" section);
`needsAccumulator` holds the matching non-negative per-need decay
accumulators. A colonist also carries a `labourTable`, a fixed
`{mine, chop, farm, haul, build, craft, cook}` map of integers 0-4 (a
priority level, 0 disables that labour kind), editable via the `set_labour`
command and all-3 for a freshly spawned colonist. Since v8 a colonist also
carries `skills` ([ADR 062](../decisions/062-skills-and-xp-per-labour.md)): the same seven
labours, each `{level, xp}` with `level` 0-10 (the length of `skills.json`'s `xp_to_next`) and
`xp` the progress inside that level (`0 <= xp < xp_to_next[level]`, 0 at level 10). A new
world seeds the levels from its seed; completed jobs raise them; nothing lowers them. The
field is optional in the validator, like `heldTool`: every colonist the game spawns, seeds or
migrates has it, and a worker without it (a hand-built test actor) works untracked.

## Critical-need interrupts and tile work progress

A critical or urgent need (`content/needs.json`'s `critical`/`urgent`
thresholds) can preempt a colonist's current job (colonist-ai.md 3.6): the
top-level `pausedJobs` field is an array of `{colonistId, jobId}` pairs naming
the job each interrupted colonist resumes once its need job resolves, and
`workProgress` is an array of `{target, ticksRemaining, ownerJobId?}` entries
recording a paused `work` toil's remaining ticks, so an interrupted
dig/chop/forage/sleep resumes instead of restarting. Only a `work` toil is
interrupted directly; a multi-toil job with no `work` phase (haul) is
preempted only at a toil boundary, and its scheduler assignment, not a tile
progress count, is what gets suspended and later resumed.

The in-memory progress key is `"<x>_<y>"`, or `"<jobId>:<x>_<y>"` for a
job-scoped key (a `rescue`, so two rescues can share a target). On the wire,
`target` plus the optional `ownerJobId` name that key exactly; both
`workProgress` and `workProgressOwners` are encoded and decoded through
`WorkProgress.key_parts()`/`key_of()`, the single codec of the key
([ADR 047](../decisions/047-work-progress-owner-records-and-ground-berry-factions.md)).

The optional top-level `workProgressOwners` field is an array of
`{target, jobId, ownerJobId?}` entries naming the exact job that owns each
`workProgress` key (a duplicate `(ownerJobId, target)` pair is rejected). Two
jobs can target the same tile at once, so ownership is persisted rather than
guessed. `WorkProgress.restore_owners()` accepts a persisted owner only if the
job still exists, is `queued`/`active`, and is a kind that ticks work. A key
with no persisted owner falls back to an entity's `work.jobId` or to
`pausedJobs`; two candidates for one key count as corruption. Any key still
unowned is dropped, so it can never leak into whichever job claims the tile
next (`WorkProgress.release_owned()` only clears keys its own job owns). An
active `incident` job's stored wait never has an owner and is kept.

The optional top-level `suspendedWorkProgress` field is an array of
`{jobId, ticksRemaining}` entries keyed by job id alone. A still-queued
(suspended, not terminated) job's `work` ticks move here, out of the shared
tile-keyed cache, as soon as its colonist's `work` is cleared for any reason
other than completion, because the scheduler may hand the same tile to a
different job's `work` toil, which must never read or overwrite them.
`WorldState._resume_work_progress()` checks this per-job store first and only
returns a tile-cache value whose recorded owner is the resuming job. A
resumed job's entry moves back into the tile cache when its `work` toil
restarts; a job cancelled or failed while suspended has its entry dropped by
`WorkProgress.release_owned()`. When absent, there are no suspended entries.

## Tool items

The top-level `toolItems` field is `{nextId, list}`, mirroring `items`: each
entry is an identity-bearing axe/pick, `{id, kind, location}`, where
`location` is `{type: "ground"|"stockpile", x, y}` or
`{type: "held", colonistId}`. `toolReservations` is a flat map of tool item id
to the job id holding it, with the same `ReservationTable` shape and
invariants as job/cell reservations. A colonist's optional `heldTool` field
names the tool item it holds, or `""` while empty-handed; absent decodes as
`""`.

## Tool fetch excluded candidates

`ToolFetchToil` (`game/scripts/core/jobs/tool_fetch_toil.gd`) tracks, per
job, which tool item ids it has already proven unreachable within that job's
current `fetch_tool` attempt (`colonist-ai.md` 2/3.3), so the next-nearest
match is tried instead. This set persists as the top-level
`toolFetchExcluded` array, one `{jobId, toolIds}` entry per job with at least
one excluded candidate; each `toolId` must reference a declared `toolItems`
entry. `StateCodec.decode()` restores it via
`ToilExecutor.restore_fetch_tool_excluded()`, and `state_hash()` includes it.

`StateCodec._restore_reroutes()` rebuilds an in-flight `fetch_tool` travel
leg's target-tile passability exception from the search's own persisted
`rerouting.target` (the tool's location when the search began), not from the
tool's current location, which differs once a held tool's holder has moved.

## Need job association and queue-entry restriction

The top-level `needJobAssignments` field is an array of `{colonistId, jobId}`
pairs, NeedGiver's record of which need job each colonist is currently
pursuing (submitted, whether or not yet assigned/active), so a need job
queued or active at save time still resumes the colonist it paused after
loading. Every scheduler queue entry (`scheduling.waiting`, each pending
batch's `candidates`/`found`, and the `scheduling.activatedEntries` map,
keyed by job id, of a job's waiting-queue entry captured when it was first
activated) carries `restrictTo`: `""` for an ordinary job, or a colonist id
when a need job may only be offered to the colonist whose need created it. A
queue entry may also carry `autonomous: true`, written only when set.

## Giver associations

Three optional top-level arrays persist giver state that cannot be safely
re-derived after a load. Each is restored after the scheduler queue so every
restored non-terminal job is re-adopted before the first tick, and each is
included in `state_hash()`:

- `rescueVictimAssignments`: `{jobId, victimId}` per `rescue` job
  (`RescueGiver.restore_victim_assignments()`); target-tile adjacency cannot
  identify a victim uniquely when two victims share a target.
- `combatBlockedTargets` ([ADR 021](../decisions/021-combat-resolution.md)):
  `{actorId, tiles}` per flee episode `CombatGiver` owns (an actor whose work
  it interrupted to flee and whose recovery it still owes), listing every flee
  destination excluded during that episode (`CombatGiver.restore_blocked_targets()`).
- `approachJobTargets` ([ADR 033](../decisions/033-hostile-approach.md)):
  `{jobId, kind, actorId}` (an actor target) or `{jobId, kind, tile}` (an
  object target) per `approach` job (`ApproachGiver.restore_job_targets()`).

## Scenario start

The top-level `scenarioStart` field (v4, [ADR 057](../decisions/057-scenario-start-fields.md))
is the part of a scenario's start that keeps ruling the world after tick 0:
`calendar` is `null` (the world runs on `content/calendar.json`) or the scenario's
own calendar document (`day_length_ticks` and `windows`, the shape of
`calendar.schema.json`); `enabledIncidents` lists the `incidents.json` ids the daily
incident draw considers, `[]` meaning every incident. `StateCodec.encode()` writes
`WorldSetup.encode()`, and `decode()` builds the world from `WorldSetup.decode()`,
so a loaded world, and a replay (which starts from a save), keeps the scenario's day
length, boosts and incident list. `CalendarValidator._valid_scenario_start()` checks
the shape (unique window ids, incident ids in the id pattern, listed once). The
scenario roster is not part of it: the saved entities are the roster. The field is
not in `state_hash()`, like the content it replaces.

## Calendar alerts

The top-level `calendarAlerts` field is `{fired: [...]}`, a flat array of
distinct calendar window ids (`game/content/calendar.json`'s `id`, e.g.
`"sow"`; any non-empty string) whose lead-time alert has already fired for
its current occurrence (ADR 008 "Calendar content schema and
CalendarService"). At each tick boundary the calendar alert giver finds the
soonest upcoming window, computes its three colony-fact booleans from live
state (`has_labour_enabled`: any colonist's `labourTable` has that window's
labour above 0; `has_plowed_plot`: any tile is `plowed_soil`;
`has_seed_stock`: any `seed` item exists) and the window's `already_fired`
flag from `calendarAlerts`, then calls `CalendarService.alert_state()`. A
`due` report is recorded into `calendarAlerts`, so the same occurrence never
fires twice, and emitted as a `calendar_alert` event carrying the window's
`id`/`label`/`days_until`.

## Incident scheduler continuation state

`IncidentScheduler` (`game/scripts/core/incidents/incident_scheduler.gd`,
ADR 017) persists its continuation state as the top-level `incidentScheduler`
field: `cooldownUntilDay`, a map from each `content/incidents.json` id to the
day a fresh draw may next consider it; `lastProcessedDay`, the day its daily
draw last ran for; and `rng`, its own `{seed, state}` snapshot, seeded from
the world seed plus `IncidentScheduler.SEED_SALT` so it never shares a draw
with `WorldState`'s `rng`. `state_hash()` covers all three (ADR 004);
`state_hash(false)` hashes the colony-only projection without them, used by
tests that compare worlds with incidents enabled and disabled. Staged (not yet
spawned) actors and the job-to-actor map are not persisted: `decode()`
re-associates each restored active incident job with its actor via
`WorldState._reconcile_incident_jobs_after_load()`, retiring one whose actor
no longer exists.

`digFindRng` (optional, `{seed, state}`) is the dig find-roll RNG
continuation ([ADR 026](../decisions/026-trench-trapped-actor-and-rescue.md)),
mirroring `rng` and `incidentScheduler.rng`; when absent, the item table keeps
its fresh stream seeded from the world seed plus `WorldState.DIG_FIND_SEED_SALT`.

## Autosave triggers

The tick-boundary trigger uses `SaveConfig.AUTOSAVE_INTERVAL_TICKS`, currently
`600`. At the viewer's base rate of two ticks per second this is five minutes.
It is based only on explicit world ticks: it does not read wall-clock time or
fire at tick zero. A failed boundary save is retried rather than advancing the
boundary bookkeeping.

The lifecycle trigger saves immediately when ticks are about to stop because
of `NOTIFICATION_APPLICATION_PAUSED` (mobile backgrounding),
`NOTIFICATION_APPLICATION_FOCUS_OUT` (including a hidden Web tab), or
`NOTIFICATION_WM_CLOSE_REQUEST` (desktop close). A successful lifecycle save
also covers the current tick boundary, preventing a duplicate save from a
queued tick notification.

`set_enabled(false)`/`is_enabled()` (see "Game sessions and New Game"
above) suspend both the tick-boundary and lifecycle triggers entirely:
neither `check()` nor a lifecycle notification saves while disabled.
Re-enabling resyncs the boundary bookkeeping to the current tick (like
`attach()`), so a game re-enabled mid-interval waits for the next real
boundary crossing rather than firing a catch-up save.
