# ADR 053: Live job storage, a bounded history of retired jobs, read-only views

> **In short:** The job queue now keeps only open jobs (queued or active). A job
> that finishes is moved to a short history of the last 256 finished jobs, which the
> viewer can still read but which is never saved. Saves therefore stop carrying
> finished jobs (save schema v2, with a migration from v1). Core code that only reads
> jobs or colonists gets the live records instead of deep copies.

- **Status:** accepted
- **Date:** 2026-10-28
- **Scope:** simulation (`game/scripts/core/jobs/`, the scheduler and the job givers),
  persistence (`StateCodec.SCHEMA_VERSION` 2, `save_migrations.gd`, `save-system.md`,
  `game-state.schema.json`)
- **Depends on:** ADR 003 (versioned saves), ADR 004 (fair scheduling), ADR 049 (schema
  reset to v1), B1 (`job_index.gd`, `job_event_log.gd`)
- **Implements:** BACKLOG A5; foundation audit §3.1 item 6 and §3.2

## Context

`JobQueue._jobs` kept every job ever submitted. Terminal jobs were never removed, so the
list, the save and `state_hash()` all grew with play time (foundation audit §2.2: 479 of
498 jobs terminal after 6,000 ticks at 10 colonists). B1 already indexed jobs by id and
kind and made the event log append-only, but the index, the save and every
`get_jobs()` copy still carried all the terminal jobs. Core readers (`HaulGiver`,
`ConstructionGiver`, `ConstructionSystem`, the scheduler, `_advance_colonists()`, the
tool toils, `CalendarAlertGiver`) read through `get_jobs()`/`get_job()`/`get_colonists()`,
which deep-copy.

The simulation reads a terminal job's record in two places only. First, through
`get_job()` right after `_finish()`: the builder slot release, the giver associations,
`check_terminal()`'s "already terminal" reason. Second, a job finished by a command keeps
its id on its colonist's route or work until the next tick's `_advance_colonists()`
drops them (the job has no assignment any more); a save taken in that window reaches
`StateCodec._restore_reroutes()`, which read the job to choose the search's cost
callable. Each terminal transition already clears the job's assignment, activation
snapshot, reservations, work-progress owner and giver links.

## Decision

1. **Live list.** `JobQueue._jobs` and `JobIndex` hold the queued and active jobs only.
   `_finish()` emits the terminal event (so the designation and pending-target indexes
   see it), then `JobIndex.remove()` drops the job from the id, kind, reservation-watch
   and labour indexes. The list and the per-kind lists are compacted in place once the
   removed jobs outnumber half of the list, so a mass cancel stays amortized O(1) per job
   and readers never see a retired job through an index. Positions in the index are
   submission ordinals, never reused.
2. **Bounded history, size 256.** The retired job goes to `JobHistory`
   (`jobs/job_history.gd`), which keeps the last `LIMIT = 256` retirements. 256 covers
   every same-call read after a finish with a wide margin (the largest is a site's builder
   count), and a few minutes of finished jobs for the viewer at 10 colonists, while
   staying small enough that `get_jobs()` merges it cheaply. `get_job()`, `get_jobs()`,
   `get_jobs_of_kinds()` and `check_terminal()` consult it; once a job is evicted it reads
   as unknown (`unknown_job` instead of `job_already_terminal`).
3. **Never saved, never hashed.** `StateCodec.encode()` writes `get_jobs(false)` (live
   jobs) and `state_hash()` hashes `get_jobs([], false)`. A loaded world starts with an
   empty history, so the history must never drive a simulation decision beyond the call
   that retired the job. `restore()` retires any terminal job it is handed.
   `_restore_reroutes()` no longer needs the record: when a route names a job the save
   does not hold, it rebuilds the search with plain passability, which is never consulted
   because the next `_advance_colonists()` drops that route before any resume
   (`test_tool_items` saves in exactly that window and stays hash-identical tick by tick).
4. **Save schema v2.** `StateCodec.SCHEMA_VERSION` is 2. The `jobs` entry shape is
   unchanged; a v2 save simply lists no terminal job. `SaveMigrations` step 1 → 2 drops
   every completed/failed/cancelled entry from `jobs` and changes nothing else. Fixture
   `save_schema_v2_fixture.json` is the R14 session written by this build; the v1 fixture
   migrates to it exactly. The validator and the JSON Schema still accept the five
   statuses, so a hand-written state with a terminal job is retired on load, not refused.
5. **Read-only views.** `JobQueue.view_job()` and `view_jobs_of_kinds()` return the live
   records (in a fresh array); `WorldState._worker_view()` returns the live worker actors.
   Their callers must never mutate them. They replace the deep copies in `HaulGiver`,
   `ConstructionGiver`, `ConstructionSystem`, `GlobalAssignment.tick()` (the roster is a
   shallow copy), `_advance_colonists()`, the tool toils, `CalendarAlertGiver` and
   `WorldState`'s own job loops. The public getters the viewer uses keep returning copies.

## Alternatives considered

- **Keep terminal jobs in the list, flagged.** Cheapest to write, but the list, the save
  and the hash keep growing; this is the problem the audit measured.
- **Remove a job from the list at once (`remove_at`).** O(N) per removal; cancelling a
  whole-map area order (~58k jobs, B1) would be O(N²) again.
- **Save the history.** Keeps `job_already_terminal` across a load, but makes the save grow
  with a diagnostic list again and puts unbounded-looking state back into the hash.
- **Unbounded history outside the save.** Same memory growth as before, only unsaved.

## Consequences

- Saves and `state_hash()` cover open jobs only; their size follows the open backlog,
  not play time.
- A command naming a job evicted from the history (or finished before a load) is
  rejected as `unknown_job` rather than `job_already_terminal`. Both are rejections with
  the same remedy family; no rule depends on telling them apart.
- The views trade safety for speed: a caller that mutated a view would mutate the
  simulation. They are confined to core readers named above, and the README for
  `jobs/` states the rule.
