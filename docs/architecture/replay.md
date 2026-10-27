# Command recording and headless replay

> **In short:** The viewer can record a session: where it started, every command it applied and
> a `state_hash()` checkpoint every N ticks. `tools\replay.ps1 <file>` rebuilds that start,
> feeds the same commands at the same ticks and compares every checkpoint. It prints the first
> tick whose hash differs, so a determinism bug is found by replaying the session that showed it.

## Pieces

| Piece | Role |
| --- | --- |
| `game/scripts/core/world/replay_log.gd` (`ReplayLog`) | The log, its JSON-safe form, and `replay()`. Core: reads the world it is handed (`state_hash()`, `to_save_state()`) and replays only through `apply()`/`tick()`. No file I/O. |
| `game/scripts/viewer/command_recorder.gd` | Viewer side: `start(world, interval)`, `observe_command(world, command, result)`, `observe_tick(world)`, `stop()`, and `write_file()`/`read_file()`. |
| `tools/replay.ps1` | Headless replay of a file. Exit 0 = every checkpoint matches, 1 = diverged, 2 = cannot replay. The small `SceneTree` script Godot runs is embedded in the `.ps1` and written to a temporary folder for each run. |
| `game/scripts/tests/test_command_replay.gd` | The acceptance test (500 ticks, mixed commands, planted nondeterminism). |

## What a recording holds

- **Start:** `WorldState.to_save_state()` at the tick recording began. A recording can start
  on any world (the boot world, a New Game, a resumed save, a session already running), so the
  seed alone is not enough: the boot world also places its starting items outside `apply()`.
  The seed, content version and generator version are kept beside it, for the reader and for
  the version check.
- **Commands:** every `apply()` call on the recorded world, in order, with the tick it ran at
  and whether it was accepted. Rejected commands are kept too: some rejections still advance a
  JobQueue sequence, and replay checks that each command is accepted or rejected exactly as it
  was.
- **Checkpoints:** checkpoint *T* is `state_hash()` right after the `tick()` that brought the
  clock to *T*, before any command of tick *T*. The first checkpoint is the start tick; then one
  every `checkpointInterval` ticks (default 10).
- **Final hash:** `state_hash()` at the last tick, after that tick's commands.

## Replay rules

1. Refuse a malformed log with `invalid_replay` (`ReplayLog.validate()`, run both on read
   and at the start of `replay()`). The checkpoints must be exactly the start tick, then every
   `checkpointInterval` ticks up to the last tick: none out of range, duplicated, off that
   grid or missing. Command ticks must never decrease. Every number read from the file
   (ticks, hashes, interval, versions) must be a whole JSON number: `40.5` is refused, never
   truncated to `40`. As a result, a replay that reports OK
   has compared every recorded checkpoint, and `replay()` checks that count again at the end.
2. Refuse with `content_version_mismatch` or `generator_version_mismatch` when the running
   build differs from the recording. A replay across content versions cannot be expected to
   match.
3. Build the world with `WorldState.from_save_state(start)` and `enable_incidents()` when the
   recording had incidents on. `decode()` always builds with incidents off, as for a Load.
4. For each tick *T*, from the start tick to the last tick: compare the checkpoint for *T* if
   one was recorded, apply the commands recorded at *T* in order, then `tick()`.
5. Stop at the first difference and report it as `diverged`. The report gives `kind`
   (`checkpoint`, `command_result` or `final_hash`), `tick` and `last_matching_tick`.
   Something that went wrong inside tick *T* shows up at the first checkpoint ≥ *T*, so the
   cause lies in the ticks after `last_matching_tick`, up to and including `tick`. With
   interval 1, `tick` is the tick itself.

## File format (`formatVersion` 1)

The file is JSON. `initialState` is a base64 Godot Variant blob
(`Marshalls.variant_to_base64`): the save state carries 64-bit RNG states, which a JSON number
(a double) cannot hold. `seed` is a decimal string for the same reason. Each recorded command is
stored as `JSON.from_native()` (`"i:0"` for an int, `"f:0.0"` for a float) and read back with
`JSON.to_native()`. That keeps types exactly: a command rejected because its tick was the
float `0.0` is still rejected on replay. A plain JSON number would come back as a float, and
turning it back into an int would make that command accepted. Every other number in the
file is small enough to survive JSON exactly.

```json
{"format": "deepholm-replay", "formatVersion": 1, "contentVersion": "1.1.0", "generatorVersion": 3,
 "seed": "20260915", "incidentsEnabled": true, "startTick": 0, "endTick": 500, "checkpointInterval": 10,
 "initialState": "<base64>", "commands": [{"tick": 0, "ok": true, "command": {"type": "Dictionary", "args": ["s:actor", "s:player", "s:command_id", ..., "s:tick", "i:0", ...]}}],
 "checkpoints": [{"tick": 0, "hash": 123}], "finalHash": 456}
```

A recording is a debugging artifact, not a save. It is never loaded as a game, and its format
does not change `game-state.schema.json`.

## Limits

- Trader offers are never persisted (`TradeSystem`), so a recording started while an offer is
  open does not carry the offer, and a later `accept_trade` command replays differently.
  Starting the recording before the trader arrives avoids this.
- The start state holds the whole save state, so a file is about 1 MB on the default map.
