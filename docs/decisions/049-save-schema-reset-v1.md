# ADR 049: Save schema reset to v1 before release

> **In short:** Before the first public release the save format starts over at
> version 1. Saves made by development builds are refused with a clear "unsupported
> pre-release save" message instead of being upgraded through 26 migration steps;
> the migration mechanism stays for the first change after release.

- **Status:** accepted
- **Date:** 2026-10-28
- **Scope:** persistence; `game/scripts/core/persistence/`, `docs/architecture/save-system.md`, `docs/architecture/contracts/game-state.schema.json`.
- **Depends on:** ADR 003 (versioned saves), ADR 048 (800/80 core size rule), backlog task R14.

## Context

The persisted state had reached `schemaVersion` 27 through 26 chained migrations
(`save_migrations.gd`, 1,532 lines), 14 frozen fixtures, a legacy-build-job
converter and a content rename for the retired `wall` object. No player has a save:
every one of them came from a development build. `save_io.gd` (2,287 lines, a
306-line validator), `save_migrations.gd` and `state_codec.gd` (1,409 lines) were
the last core files frozen above the ADR 048 size rule "until R14".

A reset needs a way to tell a pre-reset save from a v1 save. Both used the envelope
format string `"deepholm-save-v1"`, and a pre-reset save can carry `schemaVersion` 1
with an older shape, so the version number alone cannot separate them.

## Decision

1. **One schema, deepholm-save v1.** `StateCodec.SCHEMA_VERSION` is 1. The state's
   field names, nesting and value formats are exactly what R12's composed core wrote
   at version 27; only the version number changed. The JSON Schema
   (`game-state.schema.json`) has `schemaVersion: const 1` and no longer lists the
   legacy `approachRetiredActors` field, which no build has written since ADR 033's
   revision.
2. **New envelope format, old one refused.** A save is
   `{format: "deepholm-save", integrity, state}`. An envelope whose format is
   `"deepholm-save-v1"` (`SaveIO.PRE_RELEASE_FORMAT`) is a pre-release save:
   `SaveIO.read()` returns code `unsupported_pre_release_save` with a message that
   starts "unsupported pre-release save" and never returns its state. The format
   string names the file type; the version lives only in `state.schemaVersion`, so
   a later build's v2 save still gets `save_from_newer_version` from this build.
3. **Mechanism kept, chain empty.** `SaveMigrations.migrate()` and `_migrate_step()`
   stay, with no arms. The content-rename hook stays with nothing registered.
   Every later shape change bumps the version and ships a step, a
   `save_schema_vN_fixture.json` and its test (AGENTS.md "Versioned saves"). This
   reset is one-time and covers no later change.
4. **Each module validates what it persists.** `SaveIO._validate_state()` checks
   the top level and then calls one validator per persisting module
   (`persistence/validators/`) in a fixed order, so the first error reported is
   stable. Codec helpers moved out of `state_codec.gd` into `entity_codec.gd`,
   `scheduling_codec.gd` and `giver_codec.gd`. Every persistence file is under 800
   lines and the three R14 exceptions are removed from `core-budgets.json`.

## Alternatives considered

- **Keep `"deepholm-save-v1"` and reset only `schemaVersion`.** A v27 save would read
  as "newer than this build" and an old v1 save would fail with an arbitrary schema
  error: no clear message, and the acceptance test could not tell them apart.
- **Keep counting (v28 as the "release" version).** Keeps the reader honest but not
  the code: the 26 steps and fixtures would have to stay to justify the number.
- **Migrate v27 forward as the release schema.** The only v27 saves are developer
  saves; carrying the converter forever costs more than starting a new game.

## Consequences

- Developers lose their local saves once (the game says why; start a new game).
- Tests that exercised individual migration steps and the 14 pre-release fixtures
  are gone with the code they tested; current-schema round trips, the content-rename
  hook and the rejection are tested in `test_save_migration.gd`.
- Tools or tasks that compare a snapshot with the save schema (A11 replay snapshots)
  must expect `schemaVersion: 1` and the `"deepholm-save"` envelope.
- A5 (job storage) becomes the first real migration, v1 → v2.

## Acceptance criteria

- [x] `docs/architecture/save-system.md` rewritten for v1.
- [x] `game-state.schema.json` updated; the v1 fixture validates against it.
- [x] Pre-release rejection and fresh save → load → identical `state_hash` tested.
- [x] `core-budgets.json` R14 exceptions removed; no persistence file above 800 lines.
