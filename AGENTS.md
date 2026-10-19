# How AI agents contribute to this repo

> **In short:** The rules every contributor, human or AI, follows here: keep the
> game rules separate from the display, write the design down before the code,
> have a different agent review each change, and let the automated tests decide
> whether a change is ready.

Deepholm is built by AI coding agents (for example Claude Code, Codex and
GitHub Copilot) under the direction of a human integrator. This file is the
repository-wide set of operating rules for every agent and human
contributor. A more specific `AGENTS.md` in a child directory may add
constraints for that directory; it must not weaken these rules.

## The project

The game lives under `game/` and is a Godot 4 project. Every system is
designed from its own contract under `docs/architecture/` and its decision
records under `docs/decisions/`; code follows the contract, not the other
way round.

## Simulation rules

- **Plain-GDScript core.** Authoritative simulation code lives as plain
  GDScript classes under `game/scripts/core/`. It must not depend on scenes,
  nodes, rendering, UI, audio, platform services, network or wall-clock
  time.
- **Ticks and commands only.** State advances only through explicit ticks
  and validated commands. Presentation reads snapshots and events; it never
  mutates simulation state directly.
- **Injected seeded RNG.** Core rules receive a seeded random source. Never
  use global randomness in the core.
- **Stable event ordering.** Events are emitted in a deterministic order so
  that the same seed and command stream always produce the same event log
  and `state_hash()`.
- **Versioned saves.** State serialization carries a schema version, and
  every shape change ships an explicit migration and its test.
- Prefer integer or fixed-point authoritative values over floating point.
- Keep `.tscn` and `.tres` files thin. Do not hand-edit generated Godot UIDs
  or resources; generated resources are rebuilt by their builder scripts.

## One work engine and extension points

Everything a colonist does is a job (`game/content/jobs.json`) made of
toils executed by `game/scripts/core/jobs/toil_executor.gd`, scheduled by
`game/scripts/core/scheduling/global_assignment.gd` from the single
`game/scripts/core/jobs/job_queue.gd`. Decisions about *when* a job should
exist (a need, a haul, a season) live in job-giver modules, not in
`WorldState`. `WorldState` holds state, validates commands and records
events.

New behaviour enters through one of the extension points in
`docs/architecture/extension-points.md` (content, toil, job giver,
presentation, contract). A new toil or a new decision layer needs an ADR. A
per-colonist loop, a re-route path or a job-state machine added outside the
toil executor is a defect, whatever the acceptance checks say.

## Core size budgets

`docs/architecture/core-budgets.json` caps the line count of the largest
core files. The caps are checked before review. Raising a budget requires an
ADR in the same change that explains why the code cannot move into an
extension point instead.

## Contracts before code

The canonical contracts are indexed by
`docs/architecture/source-of-truth.yaml`. **Check `docs/decisions/` before
proposing architecture.** When behaviour or a public data shape changes,
update the relevant contract, schema, example and test, and add a short
numbered ADR (template: `docs/architecture/adr/000-template.md`) when the
decision crosses a boundary. Boundary changes are agreed in the contract and
ADR before the implementation lands.

## Ownership and review

- **One owner per subsystem.** Only one agent owns a file or subsystem at a
  time. The owner writes the contract into the repository and authors the
  change.
- **Independent reviewer.** The reviewer is a different agent, from a
  different provider, than the author. The reviewer receives the contract,
  acceptance criteria, changed paths and validation results alongside the
  diff. A reviewer may comment or request changes but never authors the
  reviewed change.
- **Headless tests are the review gate.** A change is not ready for review
  until the headless suite passes. Godot may be unavailable on a
  contributor machine; report that limitation instead of claiming a passing
  test.

## Working from Orca (current workflow)

Work is organised with [Orca](https://www.onorca.dev/): one git worktree per
task, Claude Code (Opus) as the author inside it, Codex as the independent
reviewer. There is no automated supervisor any more; the owner opens tasks and
merges. The operating guide is `docs/orca/README.md`.

- **Take exactly one task by id from `docs/orca/BACKLOG.md`.** Read the whole
  entry (goal, owned paths, acceptance, non-goals) before touching a file. If
  the entry is ambiguous, ask in the terminal; do not guess.
- **Refactor tasks (`R*`) follow `docs/orca/REFACTOR-PLAN.md` step by step** and
  change no behaviour. Feature tasks (`F*`) start only when their *Design* block
  is filled in.
- **Before handoff, read `docs/orca/REVIEW.md`**: it is the reviewer's script, so
  everything it checks should already be true.
- **Update your task's status row in `BACKLOG.md`** in the same change.
- **Never weaken verification.** Disabling, skipping or loosening a test, or
  raising a size budget to make a check pass, is a defect in itself.
- Windows is the development host. Godot is `$env:GODOT`; run
  `tools\run_tests.ps1` for the suite and `tools\measure_core.ps1` for the
  line counts quoted in the report.

## Validation

Run `--import` first on a fresh checkout: it builds the `.godot/` cache that
resolves `class_name` references; without it the other commands fail with
`Could not resolve external class member` parse errors. `.godot/` is ignored
by git; the generated `*.uid` files next to scripts are committed.

```text
godot --headless --path game --import
godot --headless --path game --quit-after 1
tools/run_tests.sh [path-to-godot]        # bash / CI
tools\run_tests.ps1 [-Filter name]        # Windows (uses $env:GODOT)
```

`tools/run_tests.sh` (bash) runs every `game/scripts/tests/test_*.gd`
headless and requires each to exit 0 and print `<name>: PASS`. On Windows,
the equivalent is:

```text
pwsh game/scripts/tests/run_all_tests.ps1 -GodotPath <godot>
```

For documentation and data-only changes, run `git diff --check` and
validate changed JSON files (for example with `python -m json.tool`).

## Branches and commits

Use one branch per coherent change:

```text
<backlog-id>-<short-kebab-description>          e.g. r1-extract-eventlog
```

Orca names the branch after the worktree; `tools\orca\new-task.ps1` uses
the form above.

Fetch `main` before starting and before handoff. Keep commits atomic, never
force-push a shared branch, and do not mix generated files or unrelated
cleanup into a feature.

## Handoff report

Every handoff reports:

- branch and commit;
- owned paths and the files actually changed;
- contract impact (contracts, schemas, ADRs added or updated);
- validation commands run and their results;
- known limitations;
- the next action.
