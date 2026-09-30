# ADR 010: Content registry — one loader, schema-validated, frozen at session start

> **In short:** All game data files are loaded and checked in one place when the game starts, and a save made with different game data is refused instead of loading incorrectly.

- **Status:** accepted
- **Date:** 2026-09-19
- **Scope:** content loading (`game/scripts/core/content/content_registry.gd`,
  `game/content/schemas/`), persistence (`content_version` sourcing and the
  `content_version_mismatch` load error)
- **Implements:** F1 in [`foundation-for-breadth.md`](../architecture/foundation-for-breadth.md).

## Decision

Content (`game/content/*.json`) is read through exactly one class, `ContentRegistry`, built
once at session start rather than through scattered `FileAccess`/`JSON.parse_string()` calls
or hand-copied constants. It loads every content file that has a matching schema under
`game/content/schemas/` (co-located by file name, e.g. `jobs.json` / `jobs.schema.json`),
validates each against its schema, cross-checks references between files (a job's
`needs_tool` naming a declared item, a job's toils naming toils `ToilExecutor` implements, a
need's `source_kind` naming a declared object kind), and freezes the resulting bundle
(`Dictionary`/`Array.make_read_only()`, recursively) so nothing downstream can mutate loaded
content after construction.

Content is exposed only through `get_entry(kind, id)`, `list(kind)`, `document(kind)`, and
`version()` — never a raw parsed Dictionary — so a caller cannot accidentally hold a mutable
reference into the bundle. `WorldState` reads tile move costs, job work costs, and need
thresholds from the registry at construction and injects them into `ToilExecutor`/
`NeedGiver`/`HaulGiver`'s existing constructor parameters, replacing the constants those
values used to live in.

A missing required file, a schema violation, or a dangling cross-file reference never applies
a silent default or a partially-populated bundle: it leaves the registry invalid
(`is_valid() == false`) with a typed, structured error (`get_error(): {code, message, file}`),
one of `missing_file`, `invalid_json`, `schema_violation`, or `dangling_reference`.
`ContentRegistry` itself never crashes the process on bad content — that lets a test build one
against a deliberately broken fixture and assert on the resulting error — but `WorldState`
treats an invalid registry as fatal, since the simulation cannot run on incomplete rules.

`content/manifest.json`'s `version` field becomes the save format's `contentVersion`:
`StateCodec.content_version()` reads it fresh from a `ContentRegistry` at save time instead of
a hard-coded literal. This is schemaVersion 15's only change (see `docs/architecture/
save-system.md`): `SaveIO` now compares a loaded save's stored `contentVersion` against the
content bundle actually on disk, and a mismatch is a typed `content_version_mismatch` load
error rather than a silently-accepted stale id. A rename migration hook
(`SaveMigrations.register_content_rename()`/`resolve_content_version()`, keyed by the save's
exact stored `contentVersion`) gives a future content id rename one chance to repair a
mismatch before rejection; the hook table is empty in production today.

## Consequences

- Every "add a kind of X" content change is a JSON entry plus a schema/fixture update, with no
  constant to hand-copy in core and no risk of core and content drifting silently — a dangling
  reference or a shape violation fails construction instead of shipping.
- `test_content_registry.gd` is the single place that proves the real bundle loads and every
  cross-reference resolves, and that a broken fixture (dangling reference, schema violation,
  malformed JSON, or an extra content kind with its own schema) fails construction with the
  correctly typed error rather than a partial default.
- Every save now records the content bundle that produced it and refuses to load silently
  against a different one; a genuine future content rename is a one-line hook registration, not
  a schema bump.

## Alternatives considered

- **Validate content ad hoc at each read site.** Rejected: duplicates JSON-Schema-subset logic
  across every consumer and cannot catch a dangling cross-file reference, which only exists
  once the whole bundle is loaded together.
- **Keep `contentVersion` a hard-coded literal bumped by hand alongside content changes.**
  Rejected: it drifts from the content actually on disk the moment someone edits a content
  file without remembering to bump the literal, defeating the point of the mismatch check.
