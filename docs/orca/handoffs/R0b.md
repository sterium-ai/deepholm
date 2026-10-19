# R0b — Stop `godot --import` from dirtying the worktree

> **In short:** `*.import` files are now pinned to LF in `.gitattributes`. Godot always writes
> them with LF, so a Windows checkout no longer shows 31 modified files after an import. No
> `.import` blob changed: they were already stored with LF.

## Branch and commit

- Branch: `antonelmejor50-hub/r0b-stop-godot-import-from` (Orca worktree name), rebased on
  `main` at `c4e3dc9`.
- Commits on top of `main`:
  - `9473c4f` — the `.gitattributes` rule and the README line;
  - `117cb0a` — this report, the evidence script and the backlog status;
  - `d92ef66` — review round 1: the evidence script exits nonzero on failure;
  - the final commit — this report updated for review round 1. It changes **only**
    `docs/orca/handoffs/R0b.md`; check with `git diff --stat d92ef66 HEAD`.

The suite line below is for `d92ef66`, the last commit that changes anything other than this
report (a report cannot quote a run of the commit that contains it).

## Owned paths and files changed

Owned: `.gitattributes`, `game/**/*.import`, `game/README.md` (one line).

Changed (`git diff --stat main`):

| File | Change |
| --- | --- |
| `.gitattributes` | `+ *.import text eol=lf` and a one-line comment |
| `game/README.md` | one line under *Run*: the import leaves `git status` clean |
| `docs/orca/BACKLOG.md` | R0b status `todo` → `review` (required by AGENTS.md) |
| `docs/orca/handoffs/R0b.md`, `R0b-verify.ps1` | this report and its evidence script |

No `*.import`, `.tres`, `.uid`, script or content file changed.

## Root cause

`git ls-files --eol 'game/*.import'` on `main`: all 31 files are `i/lf` (LF in the index).
With `core.autocrlf=true` and `* text=auto`, git checks them out as CRLF (`w/crlf`). Godot's
import rewrites each one with LF, and git then reports them modified although
`git diff` shows no content change (only the "LF will be replaced by CRLF" warning). Pinning
`eol=lf` makes the checkout LF, which is exactly what Godot writes, so nothing changes on disk.

### About the acceptance line "`git diff -w --stat main` empty"

The backlog expected the `.import` files themselves to need renormalising. They do not: the
blobs were already LF, so the fix is the attribute alone and the diff against `main` contains
no `.import` file at all. `git diff --stat main` and `git diff -w --stat main` are identical
and list only the files in the table above (text additions, no whitespace-only change).
`git add --renormalize game` after the change is a no-op (nothing staged), which confirms
there was nothing to normalise.

## Contract impact

None. No contract, schema or ADR touched; no save-format change.

## Validation

All run on Windows 11, Godot 4.7.2 (`$env:GODOT`).

1. **Baseline before any edit** (clean checkout of `c7c74cb`):
   `tools\run_tests.ps1` → `run_tests: all 90 test(s) PASS  [701s]`.
   Right after its import, `git status --porcelain` listed the 31
   `game/assets/generated/**/*.png.import` files as ` M`.
2. **Branch head** `d92ef66` (everything except this report; see *Branch and commit*):
   `tools\run_tests.ps1` → **`run_tests: all 90 test(s) PASS  [751s]`**
   (90 `test_*.gd` files, same as `main`; no test touched). `git status --porcelain` was empty
   before and after the run, so the suite's own import did not dirty anything either.
   An earlier run on `9473c4f` gave `run_tests: all 90 test(s) PASS  [683s]`.
3. **Fresh worktree, import twice, boot** — `docs\orca\handoffs\R0b-verify.ps1` creates a
   detached worktree of the given ref in `%TEMP%`, prints the `.import` line endings as checked
   out, runs `--import`, `--import`, `--quit-after 1`, and counts `git status --porcelain`
   lines after each step. It exits 0 and prints `R0b-verify: PASS` only if every step exits 0
   and leaves the worktree clean; otherwise `R0b-verify: FAIL` and exit 1 (exit 2 if the
   worktree cannot be created). Output at `d92ef66`:

   ```text
   PS> docs\orca\handoffs\R0b-verify.ps1 -Ref HEAD
    31 i/lf w/lf
   --import       exit=0 dirty=0
   --import       exit=0 dirty=0
   --quit-after 1 exit=0 dirty=0
   R0b-verify: PASS            (exit 0)

   PS> docs\orca\handoffs\R0b-verify.ps1 -Ref main
    31 i/lf w/crlf
   --import       exit=0 dirty=31
   --import       exit=0 dirty=31
   --quit-after 1 exit=0 dirty=31
   R0b-verify: FAIL            (exit 1)
   ```

   The import and boot steps are the same commands CI runs (`.github/workflows/ci.yml`), and
   both exit 0.
4. `git diff --check main` → clean.
5. `tools\measure_core.ps1 -Top 5` (unchanged by this task; no core file touched):

   ```text
   File                                             Total Code Comment LongestFunc     FuncLines
   game/scripts/core/world_state.gd                  4994 2703    1994 _init                  89
   game/scripts/core/persistence/save_io.gd          2217 1670     424 _validate_state       302
   game/scripts/core/persistence/save_migrations.gd  1477 1047     361 _migrate_step         105
   game/scripts/core/persistence/state_codec.gd      1422  919     393 decode                102
   game/scripts/core/worldgen/world_generator.gd     1178  727     386 place_spawn           122

   core total: 21747 lines in 48 files
   ```

### Reproduce

```powershell
git ls-files --eol 'game/*.import'            # i/lf w/lf on this branch
git diff --stat d92ef66 HEAD                  # only docs/orca/handoffs/R0b.md
docs\orca\handoffs\R0b-verify.ps1             # dirty=0 on every line, PASS, exit 0
docs\orca\handoffs\R0b-verify.ps1 -Ref main   # dirty=31 (the old behaviour), FAIL, exit 1
git diff --stat main; git diff -w --stat main # same two-file text diff + docs/orca
tools\run_tests.ps1                           # run_tests: all 90 test(s) PASS
```

## Known limitations

- An existing Windows checkout made before this change keeps its CRLF `.import` files until
  they are rewritten (the next import does it) and may show them as ` M` from stale index
  stat data once; `git add game` (stages nothing) or a fresh worktree clears it. New
  checkouts and Orca worktrees are clean from the start.
- Only `.import` files were affected; other Godot-generated text (`*.uid`, `.tres`) was not
  dirtied by the import and is out of scope.

## Review round 1 (`.orca-review.md`, Codex, REQUEST_CHANGES)

- **Blocking — suite evidence named `9473c4f`, not the reviewed head.** Fixed: the suite was
  re-run on `d92ef66`, the last commit touching anything but this report, and the report says
  how to check that the final commit only changes this file.
- **Non-blocking — `R0b-verify.ps1` should exit nonzero on failure.** Done in `d92ef66`: exit 1
  on a failed Godot step or a dirty worktree, exit 2 if the worktree cannot be created.

## Next action

Second Codex review (`tools\orca\review.ps1`), then `tools\orca\ship.ps1`.
