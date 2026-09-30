# ADR 041: A read-only move_ticks_per_tile getter for the colonist glide raises the world_state.gd core budget

> **In short:** Colonists used to jump across each tile quickly and then pause, so walking looked jerky. The display now spreads the movement evenly over the whole step, which needed one small, read-only addition to the main world-state file.

- **Status:** accepted
- **Date:** 2026-09-25
- **Scope:** `docs/architecture/core-budgets.json` cap for `game/scripts/core/world_state.gd`.

## Decision

`colonist_sprites.gd`'s `advance()` computed its glide fraction `t` as `elapsed /
seconds_per_tick()`, the duration of one simulation tick, instead of the duration
of one full tile crossing (`seconds_per_tick() * move_ticks_per_tile`,
`content/tiles.json`, currently 4). The sprite finished its glide after a quarter
of a tile crossing and then held at the destination pixel for the remaining
three quarters, which was the visible per-tile pause ("the colonist glide should
span the full tile").

The fix needs `move_ticks_per_tile` in the viewer. `test_architecture_rules.gd`'s
viewer-purity check only allows `game/scripts/viewer/*.gd` to call
`world.get_*()`/`apply()`/`get_events()`/`tick()`, and never to perform a
`ContentRegistry` read of its own (ADR 010 reserves content loading to
`WorldState`'s single frozen bundle). `WorldState.get_move_ticks_per_tile()` returns
the same value already loaded once in `_init()` (`_content.list("tiles")[0]
["move_ticks_per_tile"]`), with no new stored field and no simulation-behaviour
change.

The cap moves from 4760 to 4765: a blank separator line, a 2-line doc comment,
and the 2-line `get_move_ticks_per_tile()` function (its `func` line plus
`return`) add exactly 5 lines to the file.

## Consequences

- No other core file's budget changes.
- `colonist_sprites.gd` caches the getter's value once in `set_world()` and uses
  it in `advance()`. `test_colonist_sprites.gd` covers the corrected glide
  duration and checks constant velocity with no pause across a straight and an
  L-shaped route.

## Appendix: measurement evidence

Captured with `godot --headless --path game --script
res://scripts/tests/test_colonist_sprites.gd -- --measure`
(`_print_measurement_table()`), driving a real forage job's colonist one full
tile-crossing at x3 speed (`seconds_per_tick() = 1/6s`, 10 frames/tick,
`move_ticks_per_tile = 4` -> 40 frames/tile-crossing), sampling
`colonist_sprites.advance(1/60s)` once per simulated rendered frame exactly as
`_process()` does. Every sampled frame across the crossing is listed (none
skipped); frame 39 is the last stationary frame before the crossing starts.

**Before the fix** (`advance()` dividing by `seconds_per_tick()` alone,
temporarily restored to capture this table): the glide reaches the destination
pixel after only 10 of the 40 frames (1 of 4 ticks), then holds `x=12.0000` for
the remaining 30 frames, which is the visible pause.

```
frame,tick,x,y
39,4,-4.0000,72.0000
40,5,-2.4000,72.0000
41,5,-0.8000,72.0000
42,5,0.8000,72.0000
43,5,2.4000,72.0000
44,5,4.0000,72.0000
45,5,5.6000,72.0000
46,5,7.2000,72.0000
47,5,8.8000,72.0000
48,5,10.4000,72.0000
49,5,12.0000,72.0000
50,6,12.0000,72.0000
51,6,12.0000,72.0000
52,6,12.0000,72.0000
53,6,12.0000,72.0000
54,6,12.0000,72.0000
55,6,12.0000,72.0000
56,6,12.0000,72.0000
57,6,12.0000,72.0000
58,6,12.0000,72.0000
59,6,12.0000,72.0000
60,7,12.0000,72.0000
61,7,12.0000,72.0000
62,7,12.0000,72.0000
63,7,12.0000,72.0000
64,7,12.0000,72.0000
65,7,12.0000,72.0000
66,7,12.0000,72.0000
67,7,12.0000,72.0000
68,7,12.0000,72.0000
69,7,12.0000,72.0000
70,8,12.0000,72.0000
71,8,12.0000,72.0000
72,8,12.0000,72.0000
73,8,12.0000,72.0000
74,8,12.0000,72.0000
75,8,12.0000,72.0000
76,8,12.0000,72.0000
77,8,12.0000,72.0000
78,8,12.0000,72.0000
79,8,12.0000,72.0000
```

**After the fix** (`advance()` dividing by `seconds_per_tick() * move_ticks_per_tile`):
`x` changes by a constant 0.4000px on every one of the 40 frames and reaches the
destination exactly at the last sampled frame, with no hold.

```
frame,tick,x,y
39,4,-4.0000,72.0000
40,5,-3.6000,72.0000
41,5,-3.2000,72.0000
42,5,-2.8000,72.0000
43,5,-2.4000,72.0000
44,5,-2.0000,72.0000
45,5,-1.6000,72.0000
46,5,-1.2000,72.0000
47,5,-0.8000,72.0000
48,5,-0.4000,72.0000
49,5,0.0000,72.0000
50,6,0.4000,72.0000
51,6,0.8000,72.0000
52,6,1.2000,72.0000
53,6,1.6000,72.0000
54,6,2.0000,72.0000
55,6,2.4000,72.0000
56,6,2.8000,72.0000
57,6,3.2000,72.0000
58,6,3.6000,72.0000
59,6,4.0000,72.0000
60,7,4.4000,72.0000
61,7,4.8000,72.0000
62,7,5.2000,72.0000
63,7,5.6000,72.0000
64,7,6.0000,72.0000
65,7,6.4000,72.0000
66,7,6.8000,72.0000
67,7,7.2000,72.0000
68,7,7.6000,72.0000
69,7,8.0000,72.0000
70,8,8.4000,72.0000
71,8,8.8000,72.0000
72,8,9.2000,72.0000
73,8,9.6000,72.0000
74,8,10.0000,72.0000
75,8,10.4000,72.0000
76,8,10.8000,72.0000
77,8,11.2000,72.0000
78,8,11.6000,72.0000
79,8,12.0000,72.0000
```
