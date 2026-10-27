# ADR 047: Work-progress owners and ground berries persist explicit records

> **In short:** A save taken while a rescue was mid-work was refused, because the
> owner of the rescue's work timer was written with a garbage tile. Owners are now
> saved as explicit records naming the tile and the job scope, and ground berries
> save their faction and count in the world hash. Save schema 26 → 27.

- **Status:** accepted
- **Date:** 2026-10-27
- **Scope:** persistence
- **Implements:** backlog B5 (`docs/orca/BACKLOG.md`); diagnosis in `docs/orca/handoffs/R2.md`
  and `docs/orca/handoffs/R4.md`
- **Extends:** `docs/architecture/save-system.md` ("Critical-need interrupts and tile work
  progress", "Object and item faction ownership")

## Context

`WorkProgress` keys its timers `"<x>_<y>"`, or `"<job_id>:<x>_<y>"` for a `rescue` job
(two rescues may share a target). `StateCodec._encode_work_progress()` understood the
job-scoped form and wrote it as `{target, ticksRemaining, ownerJobId}`, but
`_encode_work_progress_owners()` split every key on `_`: `"job_120:44_33"` became
`{target: {x: 0, y: 12044}, jobId: "job_120"}`. `SaveIO.write_atomic()` then refused the
whole save (`schema_error: invalid tile coordinates`), so every save taken while a rescue
was mid-work was lost. In memory the bad entry was silently ignored and the owner was
recovered from execution state, which hid the bug from round-trip tests.

Two related gaps in the same tables: `state_hash()` left out `groundBerries`, although
it is persisted and `eat_food` consumes it; and the berries' faction map was never
persisted, so `get_ground_berries_faction_id()` returned `""` after a load for a pile
that was `"colony"` before.

## Decision

1. **One key codec.** `WorkProgress` owns the key format in both directions:
   `WorkProgress.key_of(tile, scope_job_id)` builds a key and
   `WorkProgress.key_parts(key)` returns `{tile, scope}`. `key_for_job()` and every
   encoder/decoder in `StateCodec` go through these two functions; the codec never splits
   a key itself.
2. **Owners are explicit records.** `workProgressOwners` entries are
   `{target, jobId, ownerJobId?}`. `target` + `ownerJobId` name the progress key exactly
   as a `workProgress` entry does (`ownerJobId` present only for a job-scoped key);
   `jobId` is the owning job. `SaveIO` rejects a duplicate *(ownerJobId, target)* pair,
   not a duplicate target, because two rescues can own timers on one tile.
3. **Ground berries carry their faction.** `groundBerries` entries are
   `{target, berries, factionId}`, `factionId` required (`^[a-z0-9_-]+$`), and
   `ItemTable.decode()` restores `ground_berries_factions` from it.
4. **Ground berries are hashed.** `ItemTable.hash_into()` adds `ground_berries`. Their
   factions stay out of the hash like `item_factions` (nothing reads them during a tick).
5. **Schema 27 with a migration.** `SaveMigrations._migrate_v26_to_v27()` adds
   `factionId: "colony"` to each `groundBerries` entry (`spawn_berries_item()` is the only
   writer and has always stamped `"colony"`, the same reasoning as v19's object/item
   backfill). `workProgressOwners` entries need no rewrite: a v26 file on disk can only
   hold plain-tile owners, because any job-scoped owner made the write fail.

## Alternatives considered

- **Strip the `job_id:` prefix in the owner encoder only.** Fixes the refused save but
  keeps two hand-written parsers of the same key that already diverged once, and the
  duplicate-target check would still reject two rescues on one tile.
- **Keep owners optional-shaped without a bump.** `ownerJobId` on an owner entry could
  have been added like `ownerJobId` on `workProgress`, but the berry faction field needs a
  bump anyway, and AGENTS.md asks for an explicit migration on every shape change.
- **Hash berry factions too.** Rejected for symmetry with `item_factions`; a faction
  difference does not change what any tick does today.

## Consequences

- Saves taken mid-rescue write and reload; the owner restored is the persisted one, not a
  reconstruction.
- Two worlds differing only in ground berries now hash differently; replays recorded
  before this change have different `state_hash()` values wherever berries were on the
  ground.
- Old saves (v1–v26) migrate through the chain to 27.

## Acceptance criteria

- [x] The affected canonical document is updated (`save-system.md`).
- [x] Contracts, examples, and tests are updated (`game-state.schema.json`,
      `test_work_progress_persistence.gd`, `test_save_migration.gd`).
- [x] Save/migration impact is handled (v26 → v27).
- [x] The source-of-truth index still points to the authoritative location (unchanged).
