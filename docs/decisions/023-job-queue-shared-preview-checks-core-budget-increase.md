# ADR 023: JobQueue's shared preview checks raise its core budget

> **In short:** The rules that decide whether a job order is valid now live in one place, so the
> preview shown before you click and the real order always agree. This added a few lines to one
> size-limited core file.

- **Status:** accepted
- **Date:** 2026-09-23
- **Scope:** `docs/architecture/core-budgets.json` cap for `game/scripts/core/jobs/job_queue.gd`.

## Context

`game/scripts/core/commands/command_checks.gd`'s `check_target_job_command()` and
`check_terminal_job_command()` re-implemented `JobQueue`'s `submit_dig()` priority/target rule and
`_finish()`'s unknown-job/already-terminal/not-active rule instead of sharing them. That
duplication let `WorldState.apply()`'s early priority rejection silently skip
`JobQueue.submit_dig()`'s `job_rejected` event and sequence advance for an out-of-range priority on
an otherwise valid dig/chop/forage/till/sow command.

## Decision

Add two small, pure, non-mutating predicates to `job_queue.gd` itself, so both the real mutating
path and `WorldState.preview()`'s read-only dry run consult the same rule:

- `static func check_submission(target: Vector2i, priority: int) -> Dictionary`: the predicate
  `submit_dig()` previously ran inline. `submit_dig()` now calls it and rejects on its result,
  unchanged in effect (still through `_reject()`, still emitting `job_rejected` and advancing
  `_sequence`).
- `func check_terminal(job_id: String, active_only: bool = false) -> Dictionary`: the predicate
  `_finish()` previously ran inline. `_finish()` now calls it, unchanged in effect for
  `complete()`/`cancel()`/`fail()`/`invalidate()`.

`CommandChecks.check_job_submission()` (used only by `preview()`'s dispatcher, never by `apply()`)
and `CommandChecks.check_terminal_job_command()` call these predicates instead of mirroring them.
`WorldState._apply_job_command()` is otherwise unchanged: it always calls through to
`_scheduler.submit()` -> `JobQueue.submit_dig()` for a target-valid job command, so an unsupported
priority still produces `JobQueue`'s own event and sequence advance, and its terminal branch still
goes through `JobQueue._finish()`.

This adds no decision logic: `job_queue.gd`'s submission and termination rules do not move or
change, they are only named so `command_checks.gd` can call them instead of copying them
(AGENTS.md "one work engine": no duplicated rule set). The `core-budgets.json` cap for
`job_queue.gd` rises 523 -> 549 to match the file's exact post-change line count, the convention
ADRs 015-017 use.

## Consequences

`job_queue.gd`'s public surface grows by two read-only methods. Existing callers
(`global_assignment.gd`, `command_checks.gd`, the test suite) are unaffected, since neither
predicate changes `submit_dig()`'s or `_finish()`'s external behavior, only where the rule text
lives. `JobQueue`'s clock/tick semantics, reservation table and event shapes are unchanged.
