# Agent ownership rules

> **In short:** Several people and coding agents work on the project at once.
> These rules say who is responsible for which part and how disagreements are
> settled.

These rules apply to human contributors and coding agents working in parallel.

## Ownership map

| Surface | Accountable owner | Allowed changes |
| --- | --- | --- |
| Product vision and slice criteria | Product/design owner | Update with explicit rationale |
| Simulation core and invariants | Simulation owner | Code and tests; preserve contracts |
| Content definitions and balance | Content owner | Data changes; record balance-impacting changes |
| Presentation and UX | Client owner | UI/rendering; use public commands/events |
| Persistence and migrations | Platform owner | Schema and migration code; never drop old data silently |
| Architecture documents and index | Architecture owner | Cross-cutting contract updates and ADRs |

An agent owns a file while editing it. Do not overwrite another agent's
uncommitted work. If a change crosses ownership boundaries, the initiating agent
opens an ADR or asks the accountable owner to review before merging.

## Required change discipline

- Search for an existing contract before introducing a new ID, event, or format.
- Keep public IDs stable; deprecate before removing.
- Update the schema, examples, and tests together when a contract changes.
- Keep commits focused on one architectural outcome.
- Mark inferences from research or playtests as `observed`, `inferred`, or `proposed`.

## Conflict resolution

1. Prefer the narrowest change that satisfies the slice acceptance criteria.
2. The accountable owner reviews changes to their surface.
3. Architecture owner resolves cross-surface conflicts by recording an ADR.
4. If an ADR changes a user-visible promise, product owner approval is required.

## Definition of ready

A change is ready to merge when its owner, contract impact, acceptance criteria,
tests or verification approach, migration impact, and source-of-truth location
are explicit.
