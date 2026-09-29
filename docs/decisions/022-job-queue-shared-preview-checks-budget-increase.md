# ADR 022: JobQueue's shared preview checks raise its core budget

- **Status:** accepted
- **Date:** 2026-09-23 (review round 2)
- **Scope:** `docs/architecture/core-budgets.json` cap for `game/scripts/core/jobs/job_queue.gd`.
- **Implements:** issue #346, round-2 review repair.

## Decision

Round 2 of issue #346 found that `game/scripts/core/commands/command_checks.gd`'s
`check_target_job_command()`/`check_terminal_job_command()` re-implemented `JobQueue`'s own
`submit_dig()` priority/target rule and `_finish()`'s unknown-job/already-terminal/not-active
rule, rather than sharing them — a duplication that let `WorldState.apply()`'s new early
priority rejection silently skip `JobQueue.submit_dig()`'s own `job_rejected` event and sequence
advance for an out-of-range priority on an otherwise-valid dig/chop/forage/till/sow command.

The fix adds two small, pure, non-mutating predicates to `job_queue.gd` itself, so both the real
mutating path and `WorldState.preview()`'s read-only dry run consult the same rule:

- `static func check_submission(target: Vector2i, priority: int) -> Dictionary` — the exact
  predicate `submit_dig()` already ran inline; `submit_dig()` now calls it and rejects on its
  result, unchanged in effect (still through `_reject()`, still emitting `job_rejected` and
  advancing `_sequence`).
- `func check_terminal(job_id: String, active_only: bool = false) -> Dictionary` — the exact
  predicate `_finish()` already ran inline; `_finish()` now calls it and rejects on its result,
  unchanged in effect for `complete()`/`cancel()`/`fail()`/`invalidate()`.

`CommandChecks.check_job_submission()` (consulted by `preview()`'s dispatcher only, never by
`apply()`) and `CommandChecks.check_terminal_job_command()` now call these two predicates instead
of mirroring their logic. `WorldState._apply_job_command()` is otherwise unchanged from before
issue #346: it always calls through to `_scheduler.submit()` -> `JobQueue.submit_dig()` for a
target-valid job command, so an unsupported priority still produces `JobQueue`'s own event and
sequence advance exactly as it always has; `_apply_job_command()`'s terminal branch still goes
through `JobQueue._finish()` itself for the same reason.

This is two short static/instance predicates plus their doc comments, not new decision logic —
`job_queue.gd`'s own submission/termination rules do not move or change, they are only named so a
second module (`command_checks.gd`) can call them instead of copying them (AGENTS.md "one work
engine": no duplicated rule set). `job_queue.gd`'s `core-budgets.json` cap rises 523 -> 549 to
match the file's exact post-change line count, the same convention ADR 016/017/018 already use.

## Consequences

`job_queue.gd`'s public surface grows by two read-only methods; every existing caller
(`global_assignment.gd`, `command_checks.gd`, the test suite) is unaffected since neither
predicate changes `submit_dig()`'s or `_finish()`'s external behavior — only where the rule text
lives. No change to `JobQueue`'s clock/tick semantics, reservation table, or event shapes.
