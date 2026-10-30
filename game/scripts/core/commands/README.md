# WorldState command contract

> **In short:** Every change to the game world goes through a command or a clock tick. This page lists what a command looks like, how it can be rejected, and how the world can be read without changing it.

`WorldState.apply(command)` and `WorldState.tick()`
(`game/scripts/core/world_state.gd`) are the only two ways to mutate
simulation state. This document records the wire shapes so callers can
build on them without reading the implementation.

## Command envelope

A command is a `Dictionary` with:

| field        | type       | required | notes                                  |
|--------------|------------|----------|------------------------------------------|
| `actor`      | String     | yes      | non-empty; entity issuing the command    |
| `command_id` | String     | yes      | non-empty; caller-assigned, echoed back  |
| `tick`       | int        | yes      | must equal `WorldState.get_tick()`       |
| `type`       | String     | yes      | non-empty; selects the handler           |
| `payload`    | Dictionary | yes      | values must be `String` or `int`         |

Any other payload value shape (float, bool, array, nested dictionary,
object) is rejected as `invalid_payload`. The `noop` command type records a
`command_applied` event and echoes the payload back; it exists to exercise
the mechanism, not as gameplay content. Every other command type has its own
`match` arm in `CommandRouter.apply()` (`game/scripts/core/world/command_router.gd`),
which hands it to its family's handler under `handlers/` (orders, construction,
zones, actors, incidents); a new type that introduces rejection reasons or
event `data` shapes documents them here.

## apply() result

`apply()` always returns a `Dictionary` with an `"ok"` boolean.

Success (`"ok": true`):

```gdscript
{"ok": true, "applied": {"command_id": ..., "actor": ..., "type": ..., "tick": ...}}
```

Rejection (`"ok": false`):

```gdscript
{"ok": false, "rejection": {"command_id": ..., "actor": ..., "reason": ..., "params": {...}, "tick": ...}}
```

`reason` is the stable rejection code. `params` holds codes and values only, never
player text (ADR 052): `"detail"` names the rule that failed (for example
`"target_not_tree"`, `"unknown_object_kind"` with `"kind"`), and a rejection
`JobQueue` produced carries its `"remedy"` code instead. Any other entry is a named
value the text uses (`"type"`, `"kind"`, `"trader_id"`, `"command_tick"`, ...). The
viewer words it: `StatusText.rejection_text()` looks up `rejection.<detail>` in
`data/text/<locale>.json` and fills its `{name}` placeholders from `params`, or shows
`status.remedy.<remedy>`, or else `status.reason.<reason>`. A new detail code ships
with its `en.json` entry; `test_text_pseudo_locale.gd` fails otherwise.

`command_id` and/or `actor` in a rejection may be `null` when the envelope
was malformed before that field could be read (e.g. the command was not a
`Dictionary`, or `actor` itself was missing/mistyped).

## Rejection reasons

| reason                | when                                                                                                      |
|------------------------|------------------------------------------------------------------------------------------------------------|
| `invalid_envelope`     | command is not a Dictionary, or is missing/mistyped `actor`, `command_id`, `tick`, `type`, or `payload`     |
| `invalid_payload`      | a `payload` value is not `String` or `int`                                                                 |
| `tick_mismatch`        | `command["tick"] != WorldState.get_tick()`                                                                  |
| `unknown_command_type` | `type` has no registered handler                                                                            |

Validation runs in the order above (envelope shape, then payload value
types, then tick match, then dispatch); the first failing check produces
the rejection. A `command_rejected` event is only appended when `actor` was
itself a valid non-empty string, since that is the entity ID the event is
attributed to.

## preview() (read-only dry run)

`WorldState.preview(command) -> Dictionary` runs the exact same
envelope validation and pre-mutation rule `apply()` would, without mutating
state: `state_hash()` is identical before and after a call. Returns the same
shape as `apply()` (`{"ok": true}` on success -- no `"applied"` block, since
nothing was applied; `{"ok": false, "rejection": {...}}` otherwise, with the
same `reason`/`params` `apply()` would produce for the same command). Backed
by `game/scripts/core/commands/command_checks.gd`'s `CommandChecks.check()`,
the rule set both `preview()` and (for every type but `complete_job`/
`cancel_job`/`fail_job`/`invalidate_job`) `apply()`'s own handlers consult, so
a hover/drag preview can never disagree with what committing the same command
would do. `dig`, `chop`, `forage`, `till`, `sow`, `mine`, `complete_job`,
`cancel_job`, `fail_job`, `invalidate_job`, `place_object`, `remove_object`,
`set_labour`, `set_faction`, `spawn_incident`, `zone_add` and `zone_remove`
each have a check function. `build` and `build_line` are previewed through
`ConstructionSystem`'s own checks, and `cancel_site` through
`CommandChecks.check_cancel_site_command()`: the same functions their `apply()`
handlers run. The workbench commands (`craft_set_target`, `craft_add_order`,
`craft_cancel_order`, see "Workbench commands" below) are previewed through
`CraftingSystem.check_command()`, which their handler also runs. `noop`
always previews `{"ok": true}` once envelope validation
passes (its own `apply()` handler never rejects); an unrecognized type
previews the same `unknown_command_type` rejection `apply()`'s dispatch
fallback would produce.

Where the underlying rule actually lives in `JobQueue`
(`game/scripts/core/jobs/job_queue.gd`) rather than `WorldState`, the check
function calls JobQueue's own pure, non-mutating predicate instead of
mirroring it, so the rule stays in exactly one place:

- `check_job_submission()` calls `JobQueue.check_submission(target, priority)`
  -- the same predicate `submit_dig()` itself consults before queuing a
  dig/chop/forage/till/sow job -- so an unsupported priority previews the
  same rejection `apply()` will get from `JobQueue.submit_dig()`. It is
  consulted by `preview()`'s dispatcher only: `apply()`'s
  `OrderHandler.apply_job_command()` always calls through to `JobQueue.submit_dig()`
  itself for a target-valid command, so an unsupported priority still produces `JobQueue`'s own `job_rejected`
  event and advances its sequence counter, not just an early
  `WorldState`-level rejection.
- `check_terminal_job_command()` calls `JobQueue.check_terminal(job_id,
  active_only)` -- the same predicate `JobQueue._finish()` itself consults
  for `complete_job`/`cancel_job`/`fail_job`/`invalidate_job`. It, too, is
  consulted by `preview()` only: `apply()`'s own terminal branch keeps going
  through `JobQueue._finish()` itself so a rejected terminal command still
  produces the same `job_rejected` + `command_rejected` event pair.

## Workbench commands

F2 ([ADR 061](../../../../docs/decisions/061-workbench-recipes-and-craft-labour.md)),
handled by `handlers/crafting_handler.gd`; `(x, y)` is any tile of a colony workbench:

| type | payload | effect |
|------|---------|--------|
| `craft_set_target` | `{x, y, recipe, count}`, count 0..999 | "keep `count` in stock"; 0 removes the target |
| `craft_add_order` | `{x, y, recipe, count}`, count 1..999 | appends an order; the applied result carries `"order_id"` |
| `craft_cancel_order` | `{x, y, order_id}` | removes the order; if the bench's bill serves it, its jobs end and its held inputs drop next to the bench |

Rejections (`reason`/`params.detail`): `invalid_target`/`not_a_workbench`,
`invalid_target`/`recipe_wrong_bench` (`recipe`), `invalid_target`/`unknown_craft_order`,
`invalid_payload`/`unknown_recipe` (`recipe`), `invalid_payload`/`craft_count_out_of_range`,
`invalid_payload`/`craft_payload` (a missing or mistyped field) and
`invalid_payload`/`craft_extra_field` (`field`). `WorldState.get_crafting_benches()` lists every
colony workbench with its `targets`, `orders` and `bill`.

## Reads (non-mutating)

`WorldState` keeps all authoritative storage private, in the modules it
composes (`TileGrid`, `ObjectTable`, `ItemTable`, `EventLog`, the
scheduler's `JobQueue`, ...) and its own roster, clock and RNG, and exposes
only detached copies:

- `get_seed() -> int`
- `get_tick() -> int`
- `get_tile(x, y) -> String`
- `get_tiles() -> Array[String]`
- `get_colonists() -> Array[Dictionary]`
- `get_jobs() -> Array[Dictionary]`
- `get_reservations() -> Dictionary`
- `get_events() -> Array[Dictionary]`

Every collection getter returns a deep copy; mutating the returned value
never changes `WorldState`'s internal state or its event log
(`test_world_state_determinism.gd` asserts this). `apply()` and `tick()`
remain the only two ways to change what a later `get_*()` call returns.

## Colonist shape

```gdscript
{"id": "colonist_0", "kind": "colonist", "x": 2, "y": 3}
```

Colonists are placed once at construction, inside the spawn clearing
`WorldGenerator.place_spawn()` picks (`get_spawn_clearing()`). `jobs` (`Array[Dictionary]`)
and `reservations` (`Dictionary`) start empty and are filled only through
`apply()` and `tick()`; their entry shapes are documented with the job queue
([`../jobs/README.md`](../jobs/README.md)).

## Event shape

```gdscript
{
  "type": "tick_advanced" | "command_applied" | "command_rejected",
  "tick": int,
  "system_priority": int,
  "entity_id": String,
  "sequence": int,
  "data": Dictionary,
  # "command_id": String  # command_applied / command_rejected only
}
```

`EventLog` (`world/event_log.gd`) keeps the log sorted by
`(tick, system_priority, entity_id, sequence)` at all times (binary-search
insert), per
[`docs/architecture/simulation-boundaries.md`](../../../../docs/architecture/simulation-boundaries.md#determinism-and-time).
`system_priority` is lower for commands (`WorldState.PRIORITY_COMMAND`,
`0`) than for tick-level events (`WorldState.PRIORITY_TICK`, `100`), so
within a tick, command outcomes sort before the `tick_advanced` event that
closes it out.

## Hashing and persistence

`state_hash()` hashes `JSON.stringify()` of the seed, tick, colonists, jobs,
scheduling state and every module's `hash_into()` fields — integer/string
data only, no floats, no object identity. It is a
diagnostic/test fixture for detecting divergence between two replays, not a
save format. Persistence (`schemaVersion`, `contentVersion`, and the shapes
in
[`docs/architecture/contracts/game-state.schema.json`](../../../../docs/architecture/contracts/game-state.schema.json))
is documented in [`docs/architecture/save-system.md`](../../../../docs/architecture/save-system.md).
