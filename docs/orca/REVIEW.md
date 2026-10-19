# Review guide

> **In short:** What the reviewer (Codex, a different model from the author) checks on every
> change, and the exact shape of its verdict. The author reads this before handing off, so
> the first review is already short.

The reviewer compares the branch with `main`, reads the task entry in `BACKLOG.md`, and
answers one question: **is this change safe to merge as it is?** It never edits code.

## Always

1. **Scope.** Only the task's owned paths (plus their tests/docs) changed. Anything else is
   a blocking finding, even if the extra change is good.
2. **Tests are real.** No test deleted, skipped, commented out, renamed to stop matching
   `test_*.gd`, or weakened (an assertion removed or loosened). Compare the list of
   `test_*.gd` files and the count of `_check_*`/assert sites with `main`.
3. **Suite ran.** The handoff report quotes the runner's final line
   (`run_all_tests: all N test(s) PASS` or the bash equivalent) for the branch head. A
   report without it, or with a smaller N than `main`, is blocking.
4. **Core rules (AGENTS.md).** No scene/node/rendering/wall-clock dependency entered
   `game/scripts/core/`; no global randomness; no per-colonist loop or state machine outside
   the toil executor; content literals stay in JSON (the lint step).
5. **Budgets.** `docs/architecture/core-budgets.json` caps never raised. After R12, no core
   file above 800 lines and no function above 80.
6. **Save format.** If any persisted field name, nesting or value format changed, the
   change must declare a schema bump, a migration and a fixture; otherwise it is blocking.
7. **Report honesty.** Every claim in the handoff report is checkable in the diff or the
   test output. "Should work", "not tested here" or numbers that do not match
   `tools/measure_core.ps1` are findings.

## For `R*` (refactor) tasks

- **Move, not rewrite.** For each function listed in the task, locate its new home and
  confirm the logic is the same statements in the same order. A renamed variable or
  reindented block is fine; a reordered condition, a changed default, a dropped early return
  or a "simplified" loop is a behaviour change and blocking.
- **No back-reference.** The new module never stores or receives `WorldState`. Dependencies
  are explicit `_init` parameters or `Callable`s.
- **Persistence delegated.** `state_codec.gd` calls the module's `encode`/`decode` and the
  JSON key names and value shapes are unchanged. Spot-check two fields against `main`.
- **Hash coverage unchanged.** Fields that were in `state_hash()` still are; fields that were
  deliberately excluded still are (the author's report must list both sets for the module).
- **Comment trim did not delete an invariant.** If a removed comment described a rule
  (ordering, exclusivity, "never persisted"), there is now an `assert`, a test, or one line
  of class doc that keeps it.
- **Budget lowered** to the new `world_state.gd` size.

## For `F*` (feature) tasks

- The entry's **Design** block is not *pending* and the implementation matches it line by
  line; any deviation is called out in the report with the owner's decision quoted.
- Every new behaviour has a headless test that goes through the real trigger (command,
  incident, tick), not a direct call to an internal function.
- New content has a schema entry and a `manifest.json` reference; the content lint passes.
- Determinism: a new RNG draw uses an injected, salted stream and a test shows the same seed
  reproduces the same `state_hash()`.
- Save: new persisted state ships with its schema bump, migration and fixture in the same
  change.

## Verdict format

Write exactly this, nothing else before it:

```
VERDICT: APPROVE | REQUEST_CHANGES

Blocking:
- <file:line> — <what is wrong> — <what would fix it>
(or "none")

Non-blocking:
- <file:line> — <suggestion>
(or "none")

Checked:
- scope: <ok | files outside owned paths: ...>
- tests: <N files on main, N on branch; weakened: none | ...>
- suite line quoted in report: <yes | no>
- budgets: <ok | raised: ...>
- save format: <unchanged | bump declared with migration+fixture | CHANGED WITHOUT BUMP>
```

`REQUEST_CHANGES` whenever the Blocking list is not empty. Keep each finding to one line
with a file and line; the author will read it from a terminal.
