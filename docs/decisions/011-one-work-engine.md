# ADR 011: One work engine and behaviour extension points

- **Status:** accepted
- **Date:** 2026-09-19
- **Scope:** behaviour additions under `game/scripts/core/`
- **Supersedes:** no accepted contract; this ADR makes the existing one-work-engine rule explicit.

## Decision

`WorldState` is state and orchestration, not behaviour. It validates commands,
advances authoritative state, records events, and coordinates the one work
engine. Behaviour enters only through the five documented extension points:
content, toil, job-giver, presentation, and contract.

Every colonist action is a job in the shared job queue. Job-givers decide when
a job should exist; the scheduler assigns it; the consolidated toil executor
performs its toils. New work must preserve this flow and the deterministic,
scene-independent core boundary.

## Guardrail

A per-colonist loop, a re-route path, or a job-state machine outside the toil
executor is a defect regardless of whether acceptance checks happen to pass.
Such code duplicates ownership, bypasses fairness or release semantics, and
must not be introduced as a shortcut.

## Consequences

Small changes normally touch a content file, a giver or toil module, its
focused headless test, and (when the public shape changes) the canonical
contract plus an ADR. Core file-size budgets are enforced before review;
raising a budget requires an ADR in the same change.
