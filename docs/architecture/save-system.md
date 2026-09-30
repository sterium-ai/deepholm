# Save system

> **In short:** How the game saves and loads: several rotating save files, writes that can never leave a half-written file behind, and step-by-step upgrades so saves from older versions still load.

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

`manual.json` is written only by a manual save. Autosaves never evict it. Each
autosave selects the file with the oldest recorded `(epoch, tick)` pair (see
"Game sessions and New Game" below for what `epoch` is); a missing or
unreadable file is older than every readable slot and is selected first. Thus
the order is oldest-slot-first, not a fixed round-robin order. For example,
four saves at the same epoch evict the first save and leave saves 2, 3, and 4
in the three autosave files. Selection uses the epoch/tick stored in each
file, so it survives a process restart and does not use file modification
time.

`load_best()` considers all four existing files in descending `(epoch, tick)`
order and validates them until one succeeds. Rejected candidates are returned
in trial order with their typed error code and message.

## Last-known-good save

The manager's last-known-good pointer is in memory, initially null. After a
candidate is independently validated by a successful write or `load_best()`,
it records `{slot, file, epoch, tick}`. It advances only for a strictly newer
`(epoch, tick)` pair, never points at a failed candidate, and is not a
separate persisted pointer file.

## Game sessions and New Game

`epoch` is a top-level integer field on every save (`StateCodec.encode()`
always emits `0` by default; `SaveManager.save_manual()`/`save_autosave()`
overwrite it with a caller-supplied value before writing). It is a
`SaveManager`/boot.gd session marker, not `WorldState` state -- `WorldState`
carries no session concept of its own, and `StateCodec.decode()` ignores the
field entirely when restoring a world. Ordinary continuing play (an existing
game ticking forward, an ordinary Load) always uses epoch 0 or whatever epoch
the loaded save already carried; `tick` alone orders recency within a single
epoch exactly as it always has.

boot.gd's New Game control mints a strictly higher epoch via
`SaveManager.next_epoch()` (`1 + highest_known_epoch()` across all four
slots, maxed against boot.gd's own in-memory `_current_epoch` so it is also
strictly newer than whatever game is currently live) whenever the player
starts a new game. Every save/load candidate is ordered by `(epoch, tick)`
lexicographically -- a higher epoch always outranks any tick from a lower
one -- so a freshly started, low-tick game's manual save always correctly
outranks an older game's high-tick autosave, which raw tick comparison
could not do (an old colony's autosave at tick 1000 would otherwise outrank
a brand-new game manually saved at tick 10).

New Game also suspends `AutosaveTrigger` (`set_enabled(false)`, see
"Autosave triggers" below) immediately after replacing the world, so a
ticking-but-never-saved new game cannot silently rotate into (evict) an
existing autosave slot from the game just replaced before the player has
explicitly chosen to keep it -- matching the New Game confirmation dialog's
own promise that the previous save is kept until Save is pressed. The first
successful manual Save (`_on_save_pressed()`) re-enables it; loading a
different save (`_replace_world()`, called by both Load and New Game) always
re-enables it too, since attaching to an already-persisted or freshly loaded
world has nothing pending to protect.

## Atomic writes and errors

`SaveIO.write_atomic()` validates the state, writes JSON to `<target>.tmp`,
flushes and closes it, reads the temporary file back, and verifies its
integrity and schema before one rename replaces the target. Any failure removes
the temporary file and leaves the previous target intact. The typed result
codes are:

- `write_failed` — temporary file could not be opened or flushed/closed.
- `write_interrupted` — writing was interrupted before replacement.
- `rename_failed` — the atomic replacement rename failed.
- `read_failed` — a save could not be opened.
- `parse_error` — JSON is malformed or truncated.
- `invalid_envelope` — the format, integrity field, or state envelope is absent or invalid.
- `integrity_mismatch` — the stored state hash does not match.
- `schema_error` — the state shape, type, range, enum, or current schema is invalid.
- `no_migration_available` — a required schema field is missing or an older schema has no migration.
- `save_from_newer_version` — the save was produced by a newer schema than this build.
- `content_version_mismatch` — the save's `contentVersion` does not match the content bundle
  currently on disk and no rename migration resolves it (see "Schema history and migration"
  below).

## Schema history and migration

The current persisted schema is version 25 (`StateCodec.SCHEMA_VERSION`).
Version 1 saves are migrated
explicitly to version 2: scheduler continuation fields are initialized to the
v1 starting values and the RNG state is reconstructed from the saved
seed. Version 2 saves are migrated explicitly to version 3: `groundItems`
starts as an empty array, and every entity gains `route: null` and
`work: null` (a v2 save predates trees, ground wood, and colonist
routing/work state, so there is nothing to backfill besides these fresh
placeholders); any existing `scheduling.assignments` entry that
predates the resolved-path field is backfilled with `path: []`. Version 3
saves are migrated explicitly to version 4: `objects` starts as an empty
array (a v3 save predates placeable tile objects, so there is nothing to
backfill). Version 4 saves are migrated explicitly to version 5:
only the version counter moves, since a route's optional `rerouting` field
(present only while a re-route search is actually in flight) is omitted
entirely for the normal case every v4 route was already in, so a v4 route
already satisfies the v5 shape unchanged. Version 5 saves are migrated
explicitly to version 6 (see "Items and hands" below): each `groundItems`
entry's per-tile wood counter becomes one first-class item per unit of wood,
and every entity gains `carrying: null` (a v5 save predates pick_up/place, so
no item could ever have been carried). Version 6 saves are migrated
explicitly to version 7 (see "Stockpile zones" below): a v6 save predates
player-drawn zones, so `zones` starts as an empty array and `nextZoneId`
starts at `1`; there is nothing else to backfill. Version 7 saves are migrated explicitly to version 8 (see
"Haul job fields" below): a v7 save predates the haul job kind, so every
existing job gains `itemId: ""`, `cell: null`, `retryAt: 0`, and
`backoffTicks: 0` — `JobQueue.submit_dig()`'s own harmless defaults for a
job that was never a haul job.

Version 8 saves are migrated explicitly to version 9 (see "Colonist needs"
below): a v8 save predates food/water/rest, so every entity gains a full
(100) value of each — the same value a freshly spawned colonist gets today.
Version 9 saves are migrated explicitly to version 10: a v9 save predates
berry bushes and forage, so `groundBerries` starts as an empty array. Version
10 saves are migrated explicitly to version 11 (see "Critical-need
interrupts and tile work progress" below): a v10 save predates a paused
`work` toil's tile progress, so `workProgress` and `pausedJobs` both start as
empty collections. Version 11 saves are migrated explicitly to version 12: a
v11 save predates the per-colonist labour table, so every entity gains the
default all-3 table (`{mine: 3, chop: 3, farm: 3, haul: 3, build: 3, craft:
3, cook: 3}`). Version 12 saves are migrated explicitly to version 13 (see
"Tool items" below): a v12 save predates axe/pick tool items, so `toolItems`
starts as `{nextId: 1, list: []}` and `toolReservations` starts empty; no
entity could ever have held a tool either, so a v12 entity's absent
`heldTool` is left absent rather than backfilled (`StateCodec`'s own decoder
already treats a missing `heldTool` as `""`).

Version 13 saves are migrated explicitly to version 14 (see "Need job
association and queue-entry restriction" below): a v13 save predates
NeedGiver's own persisted colonist-to-job association and a queue entry's
worker restriction, so `needJobAssignments` starts as an empty array, every
existing scheduler queue entry (`scheduling.waiting`, each pending batch's
`candidates`/`found`, and the fresh `scheduling.activatedEntries` map itself)
is backfilled with `restrictTo: ""` — no v13 save ever restricted a job to a
specific worker or tracked a job's original waiting-queue entry past its own
activation, so there is nothing more to recover.

Version 14 saves are migrated explicitly to version 15 (see F1 in
[`foundation-for-breadth.md`](foundation-for-breadth.md)): a v14 save's shape is otherwise
unchanged, so only the version counter moves. What changes at v15 is where
`contentVersion` comes from and how it is checked on load: `StateCodec.content_version()`
now reads `ContentRegistry.version()` (`content/manifest.json`'s `version` field) instead
of a hard-coded literal, and `SaveIO._read_and_verify()` compares every loaded save's
stored `contentVersion` against the content bundle actually on disk right now. A match
proceeds as before; a mismatch is given one chance to be repaired by a rename migration
hook (`SaveMigrations.register_content_rename()` / `resolve_content_version()`, keyed by
the save's exact stored `contentVersion`) before it is rejected with
`content_version_mismatch`. A successful rename re-validates the resolved state before it
is accepted.

The first production entry in this table comes from splitting walls into two kinds: `content/objects.json`'s
`wall` row was replaced by `wooden_wall` (same `build_cost`/`health`/`max_health` shape,
`build_ticks` lowered from 40 to 20) and a new `stone_wall` row, and `content/manifest.json`'s
`version` moved from `1.0.0` to `1.1.0` to mark the change. `SaveMigrations._static_init()`
registers `WALL_RENAME_FROM_CONTENT_VERSION` (`"1.0.0"`, the content version before the split)
against a remap that renames every persisted
content-id field naming the retired `wall` id: a completed `objects[].kind == "wall"` entry,
an in-progress `constructionSites[].kind == "wall"` entry (ADR 040's own persisted site
record — only its `kind` is a content id; the site's `requiredMaterials`/`heldMaterials`/
`progress`/`buildTicks`/`builderIds` are already-recorded history and are left untouched by the
rename), and a still-legacy (pre-construction-site) `jobs[].buildKind == "wall"` field —
each becomes `"wooden_wall"`. `stone_wall` is a new addition, not a rename target, so no old
save ever names it. A save written before the split, still carrying a `wall` object, site, or
legacy build job under `contentVersion: "1.0.0"`, is given exactly one chance to resolve
through this hook on load, same as any other registered rename, and reports `wooden_wall`
afterward. `register_content_rename()`/`unregister_content_rename()` remain the same
registration seam a test uses for its own scenarios; unregistering one entry never disturbs
another, including the production one.

`SaveIO._read_and_verify()` resolves a registered content-rename *before* running
`SaveMigrations.migrate_legacy_build_jobs()` (the compatibility shim for a save written before
construction sites existed — see "Build job fields" below for its `buildKind` field), not after: a legacy job's own retired `buildKind` is itself a content id, and
`migrate_legacy_build_jobs()` looks that id up against the content bundle actually on disk
right now to synthesize the new site's `requiredMaterials`/`buildTicks`. Resolving the rename
first is what lets a queued or active legacy `wall` build job synthesize a real `wooden_wall`
site with `wooden_wall`'s own current cost and duration, instead of a registry miss silently
falling back to an empty `requiredMaterials` and `buildTicks: 1` for a content id the current
bundle no longer has.
`test_save_migration.gd` covers all three renamed shapes end to end through `SaveIO.read()`:
a completed `wall` object, an unfinished `wall` construction site (continued and completed
after load, with the resulting object correctly impassable and carrying content's own current
health), and a queued legacy `wall` build job (synthesizing a site with `wooden_wall`'s real,
current `requiredMaterials`/`buildTicks`, read live off `ContentRegistry`).

A content-rename remap runs *before* `_validate_state()`, on a state that has not yet been
proven structurally sound — the current build's validator only ever knows about current
content ids, so the rename has to happen first. `_rename_wall_to_wooden_wall()` therefore only
ever touches `objects`/`constructionSites`/`jobs` when each is already present *and* typed as
an `Array`, and only renames an entry that is itself a `Dictionary`; a missing or wrong-typed
collection, or a non-`Dictionary` entry inside one, is passed through completely untouched
rather than fabricated into an empty (and therefore structurally valid-looking) collection or
blindly cast in a way that raises a script error. Either way, the malformed save reaches
`_validate_state()` exactly as malformed as it arrived and gets the same typed rejection an
ordinary (non-rename-path) save with the same defect would. `SaveIO._read_and_verify()` mirrors
this for `contentVersion` itself: it only ever attempts to resolve a rename when the stored
`contentVersion` is present and already a `String`, never coercing a missing or wrong-typed one
through `String()` first — that coercion would misreport a missing or malformed
`contentVersion` as a `content_version_mismatch` instead of the schema's own "missing required
field"/"invalid contentVersion" error. `test_save_migration.gd`'s
`_check_wall_rename_*_rejected_through_save_io()` checks cover a missing `objects`/`jobs`/
`contentVersion` field, a non-`String` `contentVersion`, and a wrong-typed container or entry
in all three renamed collections, proving each is rejected structurally rather than accepted
or crashing.

Version 15 saves are migrated explicitly to version 16 (see "Calendar
alerts" below): a v15 save predates the sowing-window calendar alert, so no
window could ever have fired yet, and `calendarAlerts` starts as
`{fired: []}`; there is nothing more to backfill.

Version 16 saves are migrated explicitly to version 17 (see "Tool fetch
excluded candidates" below): a v16 save predates the `fetch_tool` toil's own
persisted per-job excluded-candidate set, so no fetch attempt could ever have
excluded a candidate yet, and `toolFetchExcluded` starts as `[]`; there is
nothing more to backfill.

Version 17 saves are migrated explicitly to version 18 (see "Faction
membership and colonist health" below): a v17 save predates both per-actor
faction membership and persisted health, so no entity
could ever have belonged to a faction other than the colony, and no entity's
`hp`/`maxHp`/`dead` was ever actually restored across a save/load round trip
(`WorldState._ensure_health()` rebuilt a fresh one after every load instead).
`SaveMigrations._migrate_v17_to_v18()` backfills every existing entity with
`factionId: "colony"` and a full-health snapshot `{hp: 100, maxHp: 100,
dead: false}`; there is nothing more to recover. A migrated save
already carries both fields by the time `StateCodec.decode()` hands the
result to `WorldState.from_save_state()`, so `_ensure_health()`'s own
backfill (see below) only ever fires for a hand-built fixture or a live
colonist spawned this session, not for anything that passed through this
migration step.

Version 18 saves are migrated explicitly to version 19 (see "Object and item
faction ownership" below): a v18 save predates per-object and per-item
faction membership, so no object or item could ever have belonged to a
faction other than the colony — `SaveMigrations._migrate_v18_to_v19()`
backfills every existing `items.list` entry and every `objects` entry with
`factionId: "colony"`, mirroring how `_migrate_v17_to_v18()` backfilled the
same default onto every entity one version earlier.

Version 19 saves are migrated explicitly to version 20 (see "World
dimensions and generation" below, ADR 019): a v19 save predates a persisted
generator-algorithm identifier, so `map.generatorVersion` starts as `1` —
the only worldgen algorithm that has ever produced a save. `map.width`/
`map.height` need no migration: the schema already required them at v19 (see
below), and every v19 save in practice encoded them as 48/48.

Version 20 saves are migrated explicitly to version 21 (see "Incident
scheduler continuation state" below, ADR 017): a v20 save
predates incidents, so `incidentScheduler.cooldownUntilDay` starts as an
honestly empty object — no incident could ever have drawn or started a
cooldown. `lastProcessedDay` is synced to the save's own current calendar
day (`CalendarService.day_of_tick(tick)`), not `0`, so a restored world does
not treat every day it never actually lived through as newly due the moment
incidents are enabled. `rng` is freshly re-seeded the exact same
deterministic way `IncidentScheduler._init()` derives it from the save's own
seed (`seed + IncidentScheduler.SEED_SALT`); there is nothing else to
backfill.

`migrate()` chains these single-version steps, so a version-1 save reaches
the current version by passing through every intermediate version first.
Migration creates a new dictionary at each step and does not mutate the
input.

Missing required fields, malformed v1/v2 shapes, and any older version without
an explicit migration are rejected with `no_migration_available`; they are
never silently filled from current defaults. A save with a schema newer than
this build is rejected with `save_from_newer_version` and its state is not
returned. All rejected saves remain candidates for `load_best()` to report
while an older valid slot may still be loaded.

Schema version 21 stays current for per-object health (ADR 021): no
migration step or version bump was needed. Each `objects` entry gains an
*optional* `health: {hp, maxHp}` field (`StateCodec._encode_objects()`/
`_decode_objects()`, `SaveIO._valid_object_health()`), present only for an
object whose kind declares `max_health` (`content/objects.json`, e.g. `wall`/
`door`) -- mirroring how `route.rerouting` is optional for the same reason
(present only mid-search). A save written before per-object health, and any
object kind with no health at all, simply omits the field; the schema does
not require it, so an old save validates unchanged. `WorldState._ensure_object_health()`
backfills a missing entry from the object's content-declared default on the
next tick. A save that does record the field preserves a damaged wall's or
door's exact accumulated hp across a save/load round trip instead of
resetting it to full. `WorldState.state_hash()` includes
`_object_health` directly (unlike `_object_factions`, which stays out of the
hash by its own documented precedent) since a wall's remaining hp changes
future combat outcomes.

The same version also carries an *optional* top-level `combatBlockedTargets`
array (ADR 021): one `{actorId, tiles}` entry per flee
episode `CombatGiver` currently owns -- an actor whose work it interrupted
to flee and whose recovery it therefore still owes -- listing every flee
destination excluded during that episode (`tiles` is empty for an episode
that has not hit a blocked leg yet). Written by
`StateCodec._encode_combat_blocked_targets()`, validated by
`SaveIO._valid_combat_blocked_targets()`, restored by
`CombatGiver.restore_blocked_targets()` *after* the scheduler queue so every
restored non-terminal `flee` job is re-adopted for its actor before the
first tick; an old save simply omits the field. `state_hash()` includes it,
since both the episode's existence and its exclusions change the next flee
decision.

The same version also carries an *optional* top-level `approachJobTargets`
array (ADR 033): one `{jobId, kind, actorId}` (target is an
actor) or `{jobId, kind, tile}` (target is an object) entry per job
`ApproachGiver` currently tracks -- an object target has no living record to
re-scan after a load, and an actor target is not safely re-derived from
adjacency either, mirroring `rescueVictimAssignments`. Written by
`StateCodec._encode_approach_job_targets()`, validated by
`SaveIO._valid_approach_job_targets()`, restored by
`ApproachGiver.restore_job_targets()` *after* the scheduler queue so every
restored non-terminal `approach` job is re-adopted for its actor before the
first tick; an old save simply omits the field. `state_hash()` includes it,
since the association affects the next commit/adjacency decision.

An earlier version of this feature (ADR 033) also wrote an
*optional* top-level `approachRetiredActors` array: a plain list of `actor_id` strings
`ApproachGiver` had permanently retired (no job, no further search) after an `approach` job ended
without ever reaching adjacency. A later revision of ADR 033 removed that permanent
retirement in favor of retargeting the same tick a tracked job's target dies/is destroyed or goes
queued+blocked-unreachable, falling back to no approach job (never a latch) when nothing reachable
remains -- see `docs/architecture/orders-and-movement.md`'s Combat section. `StateCodec.decode()` no
longer reads `approachRetiredActors` and `encode()` no longer writes it, but the field stays accepted
by `SaveIO`'s own top-level allow-list and its structural validator (`_valid_approach_retired_actors()`,
unchanged) purely so a save written before this revision still loads.

Schema versions 22 (a persisted dig-find RNG continuation) and 23 (a trapped colonist's
persisted state) are described in
[ADR 026](../decisions/026-trench-trapped-actor-and-rescue.md). Version 24 saves are migrated
explicitly to version 25 (ADR 037; see "Items and hands" below): each entity's single-slot `carrying` field (`null`, or
`{itemId, kind, count}`) becomes `hands`, a list of `{kind, count}` entries -- empty when
`carrying` was `null`, one entry carrying its own `kind`/`count` when it was populated (a v24
save predates a colonist ever holding more than one ground item at once, so there is nothing
else to backfill). The item id is dropped: a `hands` entry never had one of its own,
even freshly after this migration -- only the ground item `place()` later creates for it gets a
new id.

Schema version 25 stays current for object footprint/rotation (ADR 039): no
migration step or version bump was needed. Each `objects` entry gains an *optional*
`orientation: "" | "horizontal" | "vertical"` field (`StateCodec._encode_objects()`/`_decode_objects()`,
`SaveIO._valid_object()`), meaningful only for a kind that declares `rotatable: true`
(`content/objects.json`) and present only when the object was placed with a non-default
orientation -- absent or an explicit `""` both mean footprint `[1, 1]`/no rotation (the
encoder never writes `""`, but a save that does must still validate and decode identically to
one that omits the field), mirroring how
`objects[].health` is optional for the same reason (present only for a kind that declares
`max_health`). A placed object whose kind's `footprint` is larger than `[1, 1]` still persists as
exactly *one* `objects` entry naming its origin tile, not one entry per occupied tile:
`WorldState._object_footprint_tiles()` (kind's footprint, swapped `[w, h]` -> `[h, w]` under
`"vertical"`) re-expands that one entry back out to every occupied tile on `decode()`, restoring
`_objects`/`_object_factions`/`_object_health` identically at each. A save written before
rotation existed, and any object whose kind is not `rotatable` (every kind today except the test-only
`test_footprint_crate`), simply omits the field; the schema does not require it, so an old save
validates unchanged.

## World dimensions and generation

Every save's `map` field is `{width, height, tiles, generatorVersion}`. A
world's dimensions are fixed for its lifetime (`WorldState._width`/`_height`).
A brand-new world's requested `p_width`/`p_height` are clamped by
`WorldGenerator.resolve_size()` into `mapgen.json`'s `min_world_size`/
`max_world_size` before generation ever runs. Restoring a save is different:
`StateCodec.decode()` writes the save's own `map.width`/`map.height` onto the
restored `WorldState` exactly as stored, never re-clamped through
`resolve_size()` — a valid small fixture below `min_world_size` (e.g. a 3x2
test save) decodes at its own exact size rather than being silently expanded.
Loading a different save replaces the whole `WorldState` instance rather than
resizing one in place. `WorldState.MAP_WIDTH`/`MAP_HEIGHT` (48x48) remain the
constructor's defaults, so every existing fixture and test that builds a
`WorldState` with no explicit size keeps getting the historical 48x48 map
unchanged; boot.gd's New Game control instead passes `mapgen.json`'s
`default_new_game_width`/`default_new_game_height` (256x256).

Terrain is generated once by the pure `WorldGenerator` module
(`game/scripts/core/worldgen/world_generator.gd`, extracted from
`world_state.gd` to respect its `core-budgets.json` cap) and is never
regenerated on load: a save's `tiles` array is restored exactly as stored.
`map.generatorVersion` records the algorithm that actually produced a world's
stored terrain: `WorldState._generator_version` defaults to the running
build's `WorldGenerator.GENERATOR_VERSION` for a freshly generated world, but
`StateCodec.decode()` overwrites it with the loaded save's own
`map.generatorVersion` — re-saving a world loaded from an older generator
build keeps recording that older version, never silently relabelled to the
current build's constant. It is a diagnostic field only, never checked
against the running build's version on load. Every mapgen.json
count/placement-attempt budget scales with `(width*height) /
(reference_width*reference_height)` (`reference_width`/`reference_height`,
default 48x48, so the ratio is 1 and nothing changes for the 48x48 fixture
case) — this is what keeps a 256x256 map from carrying the same fixed
resource counts a 48x48 map has. See
[ADR 019](../decisions/019-world-dimensions-and-generation.md).

`SaveIO._validate_state()` rejects a `tiles` array whose length does not
equal `width*height`, rejects `map.width`/`map.height` above
`mapgen.json`'s `max_world_size`, and rejects any entity/item/object/zone/
tool-item/job/queue-entry/route/groundBerries/workProgress/assignment
position at or beyond the map's own declared width/height. Every
persisted tile coordinate anywhere in the save, including nested route
`start`/`target`/`frontier`/`visited`/`cameFrom`/`path` fields and job
`target`/`cell` fields, is bounds-checked the same way — a hand-edited or
corrupted save cannot smuggle an out-of-bounds coordinate through any of
these fields, even though a live command target is already bounds-checked at
submission. A rejected write or read leaves the previous save on disk
untouched, per this page's own atomic-write guarantee above.

## Seed fidelity

The top-level `seed` field and `rng.seed`/`rng.state` are GDScript 64-bit
integers (`-9223372036854775808`..`9223372036854775807`), the full range
boot.gd's New Game seed field accepts. `JSON.parse_string()` decodes every
JSON number as a 64-bit float, which cannot exactly represent an integer
magnitude at or beyond 2^53 — reading a save back through the ordinary parsed
`Dictionary` would silently round a very large seed to the nearest
representable float. `SaveIO._read_and_verify()` recovers the exact value for
all three fields by *structurally* locating each one in the save's raw wire
text — `_locate_state_object()` walks the envelope object to find the
top-level `"state"` member, then walks `state`'s own direct members with
`_scan_object_members()`, giving `_restore_exact_seed()` and
`_restore_exact_rng()` the exact text span of `state.seed` and of
`state.rng`'s own `seed`/`state` members — rather than text-searching the
whole file for a matching key name or trusting the lossy parsed Variant.
This is a minimal hand-written JSON walk (`_scan_object_members()`,
`_skip_json_value()`, `_skip_json_array()`, `_parse_json_string()`,
`_skip_ws()`), not a regex over the whole file: a regex search cannot
distinguish "the `seed` key that belongs to `state`" from a same-named key
anywhere else in the envelope, and cannot decode a key spelled with a JSON
`\uXXXX` escape (e.g. `"\u0073eed"` for `"seed"`) — `_parse_json_string()`
decodes those while scanning key names, so an escaped key names the same
field a plain one would. An envelope-level `seed` or `rng`
field sibling to `state` is never considered, since the walk only ever
descends from the envelope root into `state`'s own members, never elsewhere.
If a field the parsed Variant says exists (`state.has("seed")`, etc.) cannot
be structurally relocated — which should never happen for text that already
parsed successfully via `JSON.parse_string()` — `SaveIO.read()` fails closed
with a typed `schema_error` rather than silently keeping the lossy
float-derived value already sitting in the parsed state.

Once located, `_parse_json_integer_token()` decomposes each field's complete
raw number token (not a bare digit prefix — a prefix match on `1e3` or `1.5`
would stop at the leading `1` and silently misread the value): a token that denotes a mathematically whole number, however it is
spelled (`1000`, `1e3`, and `1.000e3` all mean the same value), restores to
the identical exact 64-bit integer; a token with a genuine fractional
remainder, or a magnitude outside the signed 64-bit range, makes
`SaveIO.read()` reject the save as a typed `schema_error` instead of
truncating or overflowing it into a plausible-looking wrong value. The
token's exponent is bounds-checked by its own significant-digit count
*before* it is converted to an int or used to pad the mantissa with zeros: a
short token can spell an arbitrarily long exponent (e.g.
`1e999999999999999999999999`), and both converting that many digits and
padding a string to that length are bounded to reject immediately — with a
zero mantissa still resolving to exact `0` for any exponent — rather than
attempting unbounded arithmetic or allocation.

## Tool fetch excluded candidates

`ToolFetchToil` (`game/scripts/core/jobs/tool_fetch_toil.gd`) tracks, per
job, which tool item ids it has already proven unreachable within that job's
current `fetch_tool` attempt (`colonist-ai.md` 2/3.3), so the next-nearest
match is tried instead of the same excluded one forever. This set persists as
the top-level `toolFetchExcluded` array, one `{jobId, toolIds}` entry per job
with at least one excluded candidate (a job with none is simply omitted); each
`toolId` must reference a currently-declared `toolItems` entry, mirroring
`toolReservations`' own cross-check. `StateCodec.decode()` restores it via
`ToilExecutor.restore_fetch_tool_excluded()` before any further tick, and
`WorldState.state_hash()` includes it so a save/load round trip that drops or
corrupts this set is caught the same tick it diverges, not several ticks
later. Losing this set (as a save written before this field existed necessarily does) is
self-healing rather than fatal: a restored run simply re-tries an
already-ruled-out candidate for a few extra ticks before reaching the same
outcome an uninterrupted run would, since `blocked_no_tool`'s own queued/
backoff state (`jobs.json`'s `retry_base_ticks`/`retry_cap_ticks`) is fully
persisted independently of this set.

`StateCodec._restore_reroutes()` also closes a related continuity gap: a colonist's in-flight `fetch_tool` travel leg rebuilds its
route search's target-tile passability exception from the search's own
already-persisted `rerouting.target` (the tool's location at the moment the
search began), not from the tool's current location — those differ once a
held tool's holder walks somewhere else while the search is still in flight,
and using the current location would apply the exception to the wrong tile.

## Faction membership and colonist health

Each entity gains two required fields at schemaVersion 18. `factionId` (a
lowercase id string, `^[a-z0-9_-]+$`) names the faction the entity belongs
to; every actor today belongs to `"colony"` — no other faction exists yet.
A save migrated up from before this version gets both fields from
`SaveMigrations._migrate_v17_to_v18()` (see "Schema history and migration"
above), which runs once at load time before `StateCodec.decode()` ever sees
the state; separately, `WorldState._ensure_health()` backfills `factionId`
onto any colonist still missing it at runtime (a hand-built test fixture, or
a live colonist spawned this session), the same plain-append pattern
`_ensure_held_tool()` already uses.
`health` is `{hp, maxHp, dead}`, the F2 health component's own per-instance
state (`ActorHealth`, [ADR 012](../decisions/012-actors-and-components.md)).
Every spawned colonist carries this field on the live `WorldState` side;
before schemaVersion 18, `StateCodec` did not persist it, and
`WorldState._ensure_health()` rebuilt a fresh full-health value after every
load. `StateCodec._encode_entities()`/`_decode_entities()` read and write both
fields alongside every other entity field, so a colonist's actual hp
survives a save/load round trip like every other piece of its state.

## Object and item faction ownership

Every persisted object and item entry gains a required `factionId` field
(a lowercase id string, `^[a-z0-9_-]+$`) at schemaVersion 19 — the persisted
counterpart of the `faction_id` runtime field `WorldState.get_objects()`/
`get_items()` already exposed. `WorldState` tracks object/item
faction ownership in parallel maps keyed the same way as `_objects`/`_items`
(`_object_factions`, `_item_factions`), not as a nested value inside those
maps themselves; `StateCodec._encode_objects()`/`_encode_items()` read from
these maps (defaulting an untracked entry to `"colony"`, matching the
runtime getters' own default) and `_decode_objects()`/`_decode_items()`
restore them. A save migrated up from before this version gets `factionId:
"colony"` on every existing object and item from
`SaveMigrations._migrate_v18_to_v19()` (see "Schema history and migration"
above) — no object or item could ever have belonged to another faction on a
save this old.

## Tile objects

The top-level `objects` array holds at most one *logical* object per
footprint tile group (ADR 005, revised by ADR 039): each entry is
`{target: {x, y}, kind, factionId, orientation?}`, where `target` names the
object's *origin* tile, `kind` names an entry declared in
`game/content/objects.json` (for example `chair`, `door`, `wooden_wall`, `table`)
and `factionId` (added at schemaVersion 19, see "Object and item faction
ownership" above) names the faction that owns it. A kind whose content-
declared `footprint` is larger than `[1, 1]` occupies every tile of that
footprint (swapped under `orientation: "vertical"` when the kind declares
`rotatable: true`, see "Schema version 25 stays current for object
footprint/rotation" above) with the same kind/faction/health, but is still
one `objects` array entry, not one per occupied tile. `WorldState` exposes
this state through `get_object(x, y) -> String` (`""` when the tile has no
object; the same placed kind at every one of its footprint tiles) and
`get_objects() -> Array[Dictionary]` (detached `{x, y, kind, faction_id}`
copies, one per *occupied tile*, not one per logical object -- mirroring
`get_object()`'s own per-tile read). `state_hash()` covers the `objects` map
(one entry per occupied tile, exactly what `get_objects()` reads), so
adding, removing, or rotating a tile object changes the hash.

## Items and hands

The top-level `items` field is `{nextId: int, list: [...]}`. Each entry in
`list` is a first-class ground item, `{id, x, y, kind, count, factionId}`
(for example `kind: "wood"` or `"stone"`; `factionId`, added at
schemaVersion 19, see "Object and item faction ownership" above, names the
faction that owns it); `nextId` is the next never-yet-used item id counter
(`WorldState._next_item_id`), persisted alongside the list so a restored
world never reuses an id an earlier save already handed out. `WorldState`
exposes this state through `get_items() -> Array[Dictionary]` (id-sorted,
detached `{id, x, y, kind, count, faction_id}` copies) and the derived
`get_ground_wood(x, y) -> int` (the sum of every wood item's `count` at that
tile, kept for existing callers). A chop job's completion effect creates one
wood item with a fresh id (`WorldState._spawn_wood_item()`) instead of
incrementing a per-tile counter.

Each entity gains a `hands` field (ADR 037; schemaVersion 25,
replacing the single-slot `carrying` field a v24 save used): an array of at
most 4 `{kind, count}` entries, one per distinct kind currently held, every
`count >= 1`, the sum of every entry's `count` never exceeding 4
(`ActorInventory.HANDS_CAPACITY`). A `hands` entry carries no item id and no
ground position -- a `pick_up` may merge units from more than one ground
item of the same kind into one entry, and `place()` always mints a fresh
ground item id per entry it deposits.

The toil executor's `pick_up(colonist, item_id, count: int = -1)` requires
the colonist to be on or adjacent to the item's tile and the item to still
be on the ground; it moves `min(requested_count, ground_item.count,
hands_free_capacity)` units into the colonist's hands (merging into an
existing same-kind entry) and decrements the ground item's own count
(removed entirely at 0). `count < 0` (the default) requests the whole ground
stack, so a stack no larger than the colonist's free hands capacity moves in
one call, and a larger stack leaves the remainder on the ground for a later
`pick_up` to claim. `place(colonist, cell)` requires the destination cell to
still be free of any colonist or ground item; it deposits the colonist's
entire hands contents there (one fresh ground item per distinct kind held)
and clears hands. Both fail with a typed rejection reason
(`item_out_of_reach`, `item_not_found`, `destination_blocked`, or
`hands_full` when `pick_up` finds no free hands capacity at all) rather than
crashing when their precondition no longer holds by the time they run.

`state_hash()` covers both the `items` map and `_next_item_id`: two states
with the same items but different next-id counters would otherwise collide
even though they hand out different ids on the next chop, so the counter is
part of the hashed snapshot alongside the items themselves.

## Stockpile zones

The top-level `zones` field is an array of `{id, x, y, width, height}`
rectangles, each a player-drawn stockpile area (`zone_add`/`zone_remove`
commands — see `docs/architecture/orders-and-movement.md`'s "Jobs, toils and
reservations" section); `nextZoneId` is the next never-yet-used zone id
counter, persisted alongside the list for the same reason `items.nextId` is:
a restored world must never reuse an id an earlier save already handed out.
`WorldState` exposes this state through `get_zones() -> Array[Dictionary]`
(id-sorted, detached copies) and `get_zone(id) -> Dictionary` (`{}` for an
unknown id). `state_hash()` covers both the zones map and the next-id
counter, for the same reason it covers `items`/`_next_item_id`.

## Haul job fields

Every persisted job entry gains four fields, always present with harmless
defaults on every kind (`itemId: ""`, `cell: null`, `retryAt: 0`,
`backoffTicks: 0`): `itemId` (the ground item a haul job carries), `cell`
(its reserved destination `{x, y}`), and `retryAt`/`backoffTicks` (the
doubling-backoff retry state a haul job with no free destination uses —
see `docs/architecture/orders-and-movement.md`'s "Haul backoff" section).
Only `haul` jobs ever populate these beyond their defaults; `dig`/`chop`
jobs persist the same defaults for the lifetime of the save, since they are
never attached to an item or a reserved cell.

## Build job fields

A `build` job gains two further fields on top of the haul
fields above, since it hauls its declared `build_cost` item to a stockpile
leg (`target`/`itemId`/`cell`, reused unchanged from haul) and then works a
second, separate site: `site` (the tile `{x, y}` where the object will be
placed, `null` on a non-build job) and `buildKind` (the `content/objects.json`
id to place there, `""` on a non-build job). Both are optional on decode
(`StateCodec._decode_jobs()` defaults an absent `site` to `null` and an
absent `buildKind` to `""`), so no schema version bump or migration step was
needed to add them: an older save's jobs, none of which are `build` jobs,
round-trip through the same defaults untouched. `SaveIO` validates `site`
(in-bounds tile or `null`) and `buildKind` (matches the id pattern) when
present, and additionally requires both to be non-null/non-empty on any job
whose `kind` is `"build"` specifically, since activation and completion
assume a real tile and a real object kind for that one job kind. `site` and
`buildKind` are included in `WorldState.state_hash()`'s `"jobs"` entry (via
the same `get_jobs()` round trip every other job field takes), so an
in-flight wall order and an in-flight bed order at the same tick — same
`target`/`itemId`/`cell`, different `site`/`buildKind` — hash differently.

## Colonist needs and the labour table

Each entity's `needs` field is `{food, water, rest}`, every value an integer
0-100 that decays at its content-declared per-tick rate (`content/needs.json`)
and is restored by that need's own job kind (`eat_food`/`drink_water`/`sleep`
— see `docs/architecture/orders-and-movement.md`'s scheduling section for how
those jobs are chosen). Each entity also carries a `labourTable`, a fixed
`{mine, chop, farm, haul, build, craft, cook}` map of integers 0-4 (a
priority level, 0 disables that labour kind), editable via the `set_labour`
command and defaulted to all-3 for a freshly spawned colonist.

## Critical-need interrupts and tile work progress

A critical or urgent need (`content/needs.json`'s `critical`/`urgent`
thresholds) can preempt a colonist's current job (colonist-ai.md 3.6): the
top-level `pausedJobs` field is an array of `{colonistId, jobId}` pairs naming
the job each interrupted colonist will resume once its need job resolves, and
`workProgress` is an array of `{target, ticksRemaining}` entries recording a
paused `work` toil's own tile-keyed remaining tick count, so an interrupted
dig/chop/forage/sleep resumes instead of restarting. Only a `work` toil is
ever interrupted directly; a multi-toil job with no `work` phase at all
(haul) is preempted only at a toil boundary (between its instant
`pick_up`/`place` toils), and its own scheduler assignment — not a tile
progress count — is what gets suspended and later resumed or reactivated.

The optional top-level `workProgressOwners` field is an array of
`{target, jobId}` entries naming, for each `workProgress` key, the exact job
that owns it. Two different job kinds can
legitimately target the same tile at once — a `dig` submitted at a `build`'s
own site while the build is still mid-haul, for instance — so on load the
owner cannot be re-derived by asking "which job currently targets this key",
the way an earlier version of this decoder did: that guess could hand one
job's progress to the other. `WorldState._restore_work_progress_owners()`
instead trusts this field's exact job_id, cross-checked against the
just-restored job list (the referenced job must still exist, be
`queued`/`active`, and be a kind that ticks work) so a hand-edited or stale
save can never resurrect an owner pointing at a job that is gone.

`workProgressOwners` is absent for a save taken before this field existed.
Leaving every such key without an owner would be a defect:
`WorldState._release_owned_work_progress()` only clears
a key its own job_id owns, so a cancel/fail could never match an ownerless
key, and a replacement job at the same tile would silently inherit the abandoned
timer instead of starting fresh. The decoder instead recovers ownership from
execution state the wire format has always carried unconditionally, whether
or not `workProgressOwners` is present: an entity's own `work.jobId` (the job
its currently-active `work` toil belongs to) for an active job, and
`pausedJobs` for one a need interrupt suspended mid-work. Both signals only
ever exist for a job that has genuinely started its own `work` toil, so a hit
is as trustworthy as a persisted `workProgressOwners` entry — never a guess
from which job merely targets the tile. Two different candidates naming the
same key is corruption, not a legitimate ownership question, and is left
unowned rather than guessed either way; any `workProgress` key that still has
no owner after this recovery step (ambiguous, or genuinely abandoned) is
dropped outright rather than left to leak into whichever job claims the tile
next. An active `incident` job's own stored wait is the one deliberate
exception — it never carries a job_id owner even during live, uninterrupted
play (`WorldState._finish_job()`'s own `incident` branch clears it directly
instead) — so its key is recognized and excluded from this cleanup rather
than pruned.

The optional top-level `suspendedWorkProgress` field is an array of `{jobId, ticksRemaining}` entries, keyed by job_id
alone — no tile coordinate, unlike `workProgress`/`workProgressOwners`. A
still-queued (suspended, not terminated) job's own `work`-toil ticks are
moved here, out of the shared tile-keyed cache, the instant its colonist's
`work` is cleared for any reason other than that job's own completion:
JobQueue's own activation/reactivation lifecycle can hand the tile a
suspended job's released site/target reservation to a *different* job's own
`work` toil, and that job must never read, overwrite, or erase the suspended
job's saved ticks at the same `workProgress` key — `WorldState.
_resume_work_progress()` only ever returns a stored tile-cache value when its
recorded owner is the resuming job itself, and checks this per-job store
first. A resumed job's entry is consumed back into the live tile cache the
moment its `work` toil restarts; a job cancelled/failed while still suspended
has its entry dropped by the same `_release_owned_work_progress()` boundary
that already clears an owned tile-cache key. Absent for a save taken before
this field existed, restoring with no suspended entries — a suspended job
from such a save resumes at its own full declared duration instead, the same
graceful degradation `workProgressOwners`' own absence already falls back to.

## Tool items

The top-level `toolItems` field is `{nextId: int, list: [...]}`, mirroring
`items`: each entry is an identity-bearing axe/pick, `{id, kind, location}`,
where `location` is one of `{type: "ground"|"stockpile", x, y}` or
`{type: "held", colonistId}`. `toolReservations` is a flat map of tool item id
to the job id holding it, using the same `ReservationTable` shape and
invariants as job/cell reservations. Each entity's optional `heldTool` field
names the tool item id it currently holds, or `""` while empty-handed; a save
migrated from before tool items existed leaves `heldTool` absent rather than
backfilling it to `""` (the decoder already treats a missing `heldTool` as
`""`).

## Need job association and queue-entry restriction

The top-level `needJobAssignments` field is an array of `{colonistId, jobId}`
pairs, NeedGiver's own record of which need job each colonist is currently
pursuing (submitted, whether or not yet assigned/active) — persisted so a
need job already queued or active at save time still resumes the colonist it
paused after loading, the same shape `pausedJobs` already uses. Every
scheduler queue entry (`scheduling.waiting`, each pending batch's
`candidates`/`found`, and the `scheduling.activatedEntries` map, keyed by job
id, of a job's own waiting-queue entry captured the instant it was first
activated) gains a `restrictTo` field: `""` for an ordinary order-driven job,
or a colonist id when a need job may only ever be offered to the one
colonist whose need created it. Together these are what let a critical- or
urgent-need interrupt (see above) survive a save/load round trip: without
them, a colonist paused for a need job that was already committed at save
time would never be found again once its need job resolved.

## Calendar alerts

The top-level `calendarAlerts` field is `{fired: [...]}`, a flat array of
calendar window ids (`game/content/calendar.json`'s `id`, e.g. `"sow"`)
whose lead-time alert has already fired for its current occurrence (ADR 008
"Calendar content schema and CalendarService"). At each tick boundary
`WorldState` finds the soonest upcoming window (mirroring
`CalendarService.alert_state()`'s own selection), computes its three
colony-fact booleans directly from live state — `has_labour_enabled` (any
colonist's `labourTable` has that window's labour above 0),
`has_plowed_plot` (any tile is `plowed_soil`), `has_seed_stock` (any `seed`
item exists anywhere) — and this window's own persisted `already_fired` flag
from `calendarAlerts`, then calls `CalendarService.alert_state()`. A `due`
report is recorded into `calendarAlerts` (so the same window occurrence
never fires twice) and emitted as a `calendar_alert` event carrying the
window's `id`/`label`/`days_until`, through the same `_insert_event()`/
`get_events()` mechanism every other `WorldState` event uses.

## Incident scheduler continuation state

`IncidentScheduler` (`game/scripts/core/incidents/incident_scheduler.gd`, F5
"Incidents", ADR 017) owns three pieces of continuation state,
persisted as the top-level `incidentScheduler` field: `cooldownUntilDay`, a
map from each `content/incidents.json` id to the day index a fresh draw may
next consider it eligible again; `lastProcessedDay`, the day index its daily
budgeted draw last ran for; and `rng`, its own independent
`{seed, state}` RandomNumberGenerator snapshot — seeded from the world seed
combined with `IncidentScheduler.SEED_SALT` at construction, so it never
shares a single draw with `WorldState`'s own `rng` stream. `WorldState.state_hash()` covers all three fields — `cooldownUntilDay`,
`lastProcessedDay` and `rng` (ADR 004 "WorldState's diagnostic hash includes
this continuation state") — the same way it already covers every other piece
of scheduler continuation state: two otherwise-identical worlds whose day
gates differ (one due to draw on its next tick, one not) must not alias to
the same hash. `state_hash(include_incidents := false)` hashes the colony-only
projection instead, byte-identical to the formula `state_hash()` used before
incidents existed: it never includes any of the three fields, so
it stays a stable pre-incident-baseline comparison regardless of future
incident-shape changes — `test_toils_dig_chop_regression.gd`'s
`COLONY_EXPECTED_HASH` and `test_world_state_determinism.gd`'s
`_check_incidents_disabled_matches_pre_incident_baseline()` both rely on this.
`test_incidents.gd`'s own `_check_disabled_reproduces_pre_incident_hash()`
likewise compares an enabled and a disabled world's colony-only projection
before either has drawn, since `lastProcessedDay` legitimately differs
between them the moment the enabled world crosses its first calendar-day
boundary, well before any incident is actually eligible.
`incident_scheduler.gd` exposes no accessor for this state; `StateCodec.encode()`/`decode()` and `state_hash()` read and
write its fields directly, mirroring how `encode()` already reads
`world._random`/`world._tiles` directly rather than through a getter.
Staged (proposed but not yet spawned) actors and the job-id-to-actor-id map
are never persisted — `StateCodec.decode()` re-associates each restored
active incident job with its actor via `WorldState._reconcile_incident_jobs_after_load()`
instead, retiring one whose actor no longer exists.

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
above) suspend both the tick-boundary and lifecycle triggers
entirely: neither `check()` nor a lifecycle notification saves while
disabled. Re-enabling resyncs the boundary bookkeeping to the current tick
(like `attach()`), so a game re-enabled mid-interval waits for the next real
boundary crossing rather than immediately firing a catch-up save for every
boundary ticked past while suspended.
