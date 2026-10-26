# ADR 045: Story and quest layer (trigger → condition → effect)

> **In short:** Story beats, warnings and quests become content rules: "when this happens,
> if these things are true, issue these commands". One story giver reads them once per tick
> and sends ordinary commands, so a story never adds new code to `WorldState`. Its flags and
> quest stages are saved like any other module, and an incident is just one thing a rule can
> fire.

- **Status:** proposed (owner sign-off pending)
- **Date:** 2026-10-26
- **Scope:** simulation, content, persistence. Design only; no code lands with this ADR.
- **Depends on:** [ADR 011](011-one-work-engine.md) (one work engine, job-giver pattern),
  [ADR 010](010-content-registry.md) (content registry),
  [ADR 017](017-incidents-core-budget-increase.md) and
  [ADR 034](034-incident-lingering-actors.md) (incidents),
  [ADR 008](008-calendar-content-schema.md) (calendar windows).
- **Related tasks:** A6 (event cursor), A13 (content packs), A15 (text keys), A16
  (scenarios), R10 (command router), R12 (tick pipeline), R14 (save schema reset).

## Context

`docs/architecture/foundation-audit.md` §3.5 found that the only scripted content is the
incident table: five rows in `game/content/incidents.json`, drawn by
`IncidentScheduler._run_daily_draw()` against `DAILY_BUDGET_POINTS := 3`, `min_day` and
`cooldown_days`. Nothing in the core has a trigger, a condition, a flag, a chain or a quest
state, and `incidents.schema.json` forbids extra fields. A story beat ("scouts warn of a raid,
two days later it arrives") would today be new code in `WorldState`, which ADR 011 forbids.

What already exists and is reused unchanged:

- **Commands in, events out.** `WorldState.apply(command)` validates an envelope
  (`actor`, `command_id`, `tick`, `type`, `payload` with `String`/`int` values only;
  `game/scripts/core/commands/README.md`) and `CommandChecks` gives a non-mutating
  `preview()` for every type. `spawn_incident` and `set_faction` are commands already.
- **Events.** Every system emits ordered events (`(tick, system_priority, entity_id,
  sequence)`) through `EventLog`: `incident_started`, `calendar_alert`, `attacked_by`,
  `trade_offer`, `need_unmet`, the job queue's `job_*` events.
- **Job-giver pattern.** `CalendarAlertGiver` already does a small version of this: it reads
  colony facts through injected `Callable`s once per tick, keeps one-shot `already_fired`
  state that `WorldState` persists (`calendarAlerts`), and emits an event. `IncidentScheduler`
  persists its cooldowns, last processed day and its own salted RNG (`incidentScheduler` in
  the save).

## Decision

### 1. Model

A **rule** is `trigger → conditions → effects`:

- the **trigger** says *when* the rule is looked at: at the start of a calendar day, or when
  a matching event was emitted;
- the **conditions** are a flat list of read-only checks that must all be true (AND only; an
  OR is two rules);
- the **effects** are an ordered list of **ordinary commands**, sent through the same
  `apply()` path the player and the debug viewer use.

A **flag** is a named integer (default `0`). A **quest** is a declared, ordered list of
stages; its state is the current stage id and the tick it was entered. Flags and quest state
are the only story memory, and both are persisted module state (section 5).

There is no expression language, no script and no per-colonist logic in the story layer.
It decides *when* commands are issued, exactly like a job giver decides when a job exists.

### 2. Content

Two new collection kinds in `ContentRegistry.COLLECTION_KINDS`, each with a schema under
`game/content/schemas/` and the usual load → validate → cross-check → freeze path:

**`game/content/quests.json`** (id field `id`):

```json
{
  "quests": [
    {
      "id": "raid_warning",
      "title": "story.raid_warning.title",
      "visible": true,
      "stages": [
        {"id": "warned"},
        {"id": "incoming"},
        {"id": "repelled", "terminal": true}
      ]
    }
  ]
}
```

`title` is a text key (A15), never English. `visible: false` marks a bookkeeping quest the
viewer does not list (a chain's progress). A `terminal` stage ends the quest.

**`game/content/story.json`** (id field `id`):

```json
{
  "story": [
    {
      "id": "raid_warning_1_scouts",
      "trigger": {"on": "day_start"},
      "conditions": [
        {"fact": "day", "op": ">=", "value": 12},
        {"fact": "quest_stage", "args": {"quest": "raid_warning"}, "op": "==", "value": ""}
      ],
      "chance_percent": 100,
      "repeat": "once",
      "effects": [
        {"command": "story_message", "payload": {"text": "story.raid_warning.scouts", "severity": "warning"}},
        {"command": "set_quest_stage", "payload": {"quest": "raid_warning", "stage": "warned"}}
      ]
    }
  ]
}
```

Field rules:

| field | shape | notes |
| --- | --- | --- |
| `trigger.on` | `"day_start"` \| `"event"` | `day_start` fires once per calendar day, on the first tick of that day. |
| `trigger.event` | event type string | required when `on` is `"event"`. |
| `trigger.match` | `{field: String\|int}` | optional; every listed key must equal the event's `data[field]`. |
| `conditions[]` | `{fact, args?, op, value}` | `op` is one of `== != < <= > >=`; `value` is an `int`, or a `String` for facts that return one (`==`/`!=` only). |
| `chance_percent` | int 1..100, default 100 | rolled on the story RNG only after every condition passed. |
| `repeat` | `"once"` \| `"always"` \| `{"cooldown_days": N}` | `once` never fires again; `always` fires on every matching trigger; a cooldown gates the next firing. |
| `effects[]` | `{command, payload}` | `command` must be in the effect whitelist (section 3); payload values are `String`/`int`, as in every command. |

**Event bindings.** In a rule whose trigger is `event`, a payload string of the form
`"$event.<field>"` or `"$event.<field>.<index>"` is replaced by that value of the triggering
event's `data` before the command is built (for example `"$event.actor_ids.0"`). Nothing
else is templated. The registry rejects `$event` in a `day_start` rule.

**Facts** are a closed vocabulary, each a read-only query injected into the giver (no
`WorldState` reference, REVIEW.md "no back-reference"):

| fact | args | returns |
| --- | --- | --- |
| `day` | — | `CalendarService.day_of_tick(tick)` |
| `colonist_count` | — | actors whose `factionId` is `colony` |
| `actor_count` | `faction` | actors of that faction in the world (staged incident actors excluded) |
| `food_count` | — | ground berries, the colony's only food today |
| `item_count` | `item` | the places `_has_item_of_kind()` already searches (ground, stockpile, carried) |
| `object_count` | `kind` | placed, finished objects of that kind (construction sites excluded) |
| `flag` | `flag` | the flag's value, `0` if never set |
| `quest_stage` | `quest` | current stage id, `""` if not started |
| `days_in_stage` | `quest` | whole days since the current stage was entered; `-1` if not started |
| `window_open` | `window` | `1` while that calendar window is open, else `0` |
| `days_until_window` | `window` | days until the window's next `from`; `-1` if none ahead |

A new fact is a code change (one query function, its schema enum value, a test), not a
content change, so the vocabulary stays small and reviewable.

**Cross-checks** (`ERROR_DANGLING_REFERENCE` or `schema_violation`, as for other kinds): an
event type in a trigger that is not in the giver's published list of core event types, an unknown fact, a missing or unknown fact argument (faction,
item, object kind, window, quest), a `quest_stage` value that is not `""` or a stage of that
quest, an effect command outside the whitelist, a `spawn_incident` naming an undeclared
incident, a `set_quest_stage` naming an undeclared quest or stage, a flag read by a condition
that no rule's effect ever sets, and an `$event` binding in a `day_start` rule.

### 3. Effects are commands

The effect whitelist is the set of command types a rule may send. Two exist today; four are
new, small commands with their own `CommandChecks` function, `apply()` handler (an R10
`commands/handlers/story.gd` family) and documented rejection reasons:

| command | exists | payload | what it does |
| --- | --- | --- | --- |
| `spawn_incident` | yes | `{id}` | the incident's actors, through `IncidentScheduler.force_spawn()` |
| `set_faction` | yes | `{target, faction_id}` | e.g. a migrant joins the colony |
| `set_story_flag` | new | `{flag, value}` | sets a flag; emits `story_flag_set` |
| `set_quest_stage` | new | `{quest, stage}` | moves a quest; emits `quest_stage_changed {quest, from, to}` and, on a terminal stage, `quest_finished {quest, stage}` |
| `story_message` | new | `{text, severity, ...params}` | emits `story_message {rule_id, text, severity, params}` for the viewer's alert list; no state change |
| `end_scenario` | new | `{outcome, text}` | records the outcome (`won`/`lost`) and emits `scenario_ended`; this is the win/lose hook A16 left to A17 |

Because they are commands, every effect is validated by the same rules a player command is,
is previewable, appears in the event log as `command_applied`/`command_rejected`, and is
recorded by A11's replay recorder for free. The four new commands are also usable from the
debug viewer, like `spawn_incident` is today.

The envelope of a story command is `actor: "story"`, `command_id:
"story:<rule_id>:<tick>:<effect_index>"`, `tick: <current tick>`; `story_message` receives
`rule_id` from the giver, not from content.

**Incidents become one effect kind.** A rule fires an incident through `spawn_incident`; the
incident row keeps describing *what* arrives (faction, actor, count, edge, wait). The ambient
daily draw stays as it is (`IncidentScheduler` keeps its own RNG stream and budget, so
existing seeds and saves keep their incidents). An incident row gains one optional field,
`"draw": "daily" | "story"` (default `"daily"`); a `"story"` row is never picked by the daily
draw and only arrives when a rule (or the debug command) sends it. Folding the daily draw
itself into story rules is deferred (Alternatives).

### 4. Evaluation: one story giver

`game/scripts/core/story/story_giver.gd` (`StoryGiver`, `RefCounted`), constructed by
`WorldState` like the other givers, with explicit `_init` parameters only: the content
registry, a facts record (the `Callable`s in section 2), `apply_command: Callable` (the R10
router's `apply`), `events_since: Callable` (A6's cursor read; until A6 lands, a read of
`EventLog` by sequence), and the world seed for its RNG. It holds no `WorldState` reference.

It runs **once per tick, as the last phase before `tick_advanced`**: in today's `tick()` after
`_incidents.advance()`, and in R12's `TickPipeline` as a `story` phase after `incidents` and
`calendar`. Each run:

1. **Collects triggers.** `day_start` if the calendar day changed since the last run; plus
   every event with a sequence greater than the giver's cursor and not later than the last
   event that existed when the phase began. Effects' own events therefore wait for the next
   tick: a chain advances at most one hop per tick, so no rule can loop inside a tick.
2. **Walks rules in ascending `id` order** (the registry's frozen order, independent of file
   order or packs). For each rule, triggers are taken in the order collected (`day_start`
   first, then events by sequence). Per trigger occurrence: check `repeat`, then the
   conditions against **live state** (so an earlier rule's effects this tick are visible to a
   later rule), then `chance_percent`.
3. **Fires.** Every effect is first `preview()`ed with its bindings resolved. If any preview
   is rejected, the rule does not fire, is not marked as fired, and the giver emits
   `story_rule_skipped {rule_id, effect_index, reason}`; it will be looked at again on its next
   trigger. Otherwise each effect is `apply()`d in listed order. An `apply()` that still
   rejects (an earlier effect of the same rule changed the outcome) is logged as
   `command_rejected` by the router as usual and the remaining effects still run; the rule
   counts as fired. Effects are not rolled back.
4. **Budget.** At most `MAX_FIRINGS_PER_TICK := 8` firings per run. When the budget is spent
   the cursor stops at the last trigger processed and the rest (including a still-pending
   `day_start`) is taken next tick, in the same order. Nothing is dropped.

**Determinism.** Rule order, trigger order and event order are all total and seed-independent.
The only random draw is `chance_percent`, from the giver's own `RandomNumberGenerator`, seeded
`world_seed + SEED_SALT` with a salt distinct from every other stream (the
`IncidentScheduler.SEED_SALT` pattern), drawn only when a rule with `chance_percent < 100`
has passed its conditions. The same seed and command stream reproduce the same firings,
events and `state_hash()`.

**Cost.** Conditions are evaluated only on a trigger, never polled every tick. A `day_start`
rule costs once per 2,200 ticks; an `event` rule costs once per matching event. Facts are
counts over existing tables; when A2/A3 add indices, the facts use them.

### 5. Persistence and hashing

New top-level save key `story`, encoded and decoded by the module (`StoryGiver.encode()` /
`decode()`, called from `state_codec.gd`) and validated by the module's own validator (R14's
per-module split):

```json
"story": {
  "flags": {"migrant_chain_done": 1},
  "quests": {"raid_warning": {"stage": "warned", "enteredTick": 26400}},
  "rules": {"raid_warning_1_scouts": {"fired": 1, "lastDay": 12}},
  "lastDay": 12,
  "rng": {"seed": 123, "state": 456}
}
```

- Keys are sorted on encode, as elsewhere. An unknown flag, quest, stage or rule id in a save
  is a typed load error (`schema_error`), not silently dropped; A13's pack list makes that
  error explain which pack is missing.
- The event **cursor is not persisted**: events are not persisted either (A0 §3.2), so on
  decode it is set to the restored log's head. Consequence, accepted: an event emitted by a
  player command after the last tick and before a save is not seen by `event` rules after that
  save is loaded. Rules that must not miss a beat use `day_start` with state conditions.
- A shape change, so the code task ships a schema bump, a migration that adds an empty
  `story` block (`{flags:{}, quests:{}, rules:{}, lastDay: <day of the saved tick>, rng: <seeded
  from the save's seed>}`) and a fixture. If it lands after R14, it is v1 → v2.
- `state_hash()` covers `flags`, `quests`, `rules`, `lastDay` and the RNG state: they decide
  future commands, so two worlds that differ only there must hash differently.

### 6. Presentation

The viewer reads `story_message`, `quest_stage_changed`, `quest_finished` and
`scenario_ended` events and a read-only `get_quests()` snapshot (visible quests, current
stage, text keys). It resolves text keys through `TextTable` (A15) and appends story messages
to the same standing-alert list `incident_started` and `calendar_alert` use. A quest panel is
a later presentation task, not part of the core.

## Worked examples

All three use only the vocabulary above. Rule ids carry a numeric step so the ascending-id
walk is also the reading order.

### A. A migrant chain

Two travellers arrive some days apart; each joins the colony only once it has walked in. Uses
a hidden quest as the chain's memory.

```json
{"id": "migrant_chain", "title": "story.migrant_chain.title", "visible": false,
 "stages": [{"id": "first_coming"}, {"id": "first_joined"}, {"id": "second_coming"},
            {"id": "done", "terminal": true}]}
```

```json
[
  {"id": "migrant_chain_1_first", "trigger": {"on": "day_start"},
   "conditions": [{"fact": "day", "op": ">=", "value": 8},
                  {"fact": "quest_stage", "args": {"quest": "migrant_chain"}, "op": "==", "value": ""},
                  {"fact": "object_count", "args": {"kind": "bed"}, "op": ">=", "value": 2}],
   "repeat": "once",
   "effects": [{"command": "story_message", "payload": {"text": "story.migrant.first_seen", "severity": "info"}},
               {"command": "spawn_incident", "payload": {"id": "migrant_joins"}},
               {"command": "set_quest_stage", "payload": {"quest": "migrant_chain", "stage": "first_coming"}}]},

  {"id": "migrant_chain_2_join", "trigger": {"on": "event", "event": "incident_actor_arrived",
                                             "match": {"incident_id": "migrant_joins"}},
   "conditions": [],
   "repeat": "always",
   "effects": [{"command": "set_faction", "payload": {"target": "$event.actor_id", "faction_id": "colony"}},
               {"command": "story_message", "payload": {"text": "story.migrant.joined", "severity": "info"}}]},

  {"id": "migrant_chain_3_advance", "trigger": {"on": "event", "event": "incident_actor_arrived",
                                                "match": {"incident_id": "migrant_joins"}},
   "conditions": [{"fact": "quest_stage", "args": {"quest": "migrant_chain"}, "op": "==", "value": "first_coming"}],
   "repeat": "once",
   "effects": [{"command": "set_quest_stage", "payload": {"quest": "migrant_chain", "stage": "first_joined"}}]},

  {"id": "migrant_chain_4_second", "trigger": {"on": "day_start"},
   "conditions": [{"fact": "quest_stage", "args": {"quest": "migrant_chain"}, "op": "==", "value": "first_joined"},
                  {"fact": "days_in_stage", "args": {"quest": "migrant_chain"}, "op": ">=", "value": 3},
                  {"fact": "food_count", "op": ">=", "value": 10}],
   "chance_percent": 50,
   "repeat": {"cooldown_days": 1},
   "effects": [{"command": "story_message", "payload": {"text": "story.migrant.second_seen", "severity": "info"}},
               {"command": "spawn_incident", "payload": {"id": "migrant_joins"}},
               {"command": "set_quest_stage", "payload": {"quest": "migrant_chain", "stage": "done"}}]}
]
```

What it needs that does not exist yet: the `incident_actor_arrived` event. Today
`migrant_joins` emits only `incident_started`, at *proposal* time, while the actor is still
staged and not in the roster, so `set_faction` on it would be rejected (`invalid_target`).
`IncidentScheduler.on_job_finished()` must emit `incident_actor_arrived {incident_id,
actor_id}` when a lingering actor's arrival job ends (the staged entry carries the incident
id). `migrant_joins` also becomes `"draw": "story"` so it no longer arrives from the daily
draw as a permanent `allies` visitor. Steps 2 and 3 share one trigger: step 2 (lower id) runs
for every migrant, step 3 only while the chain waits for the first one, so the second
migrant joins without moving the quest back.

### B. A raid warning

Scouts warn; two days later the raiders come; the quest ends when none are left.

```json
{"id": "raid_warning", "title": "story.raid_warning.title", "visible": true,
 "stages": [{"id": "warned"}, {"id": "incoming"}, {"id": "repelled", "terminal": true}]}
```

```json
[
  {"id": "raid_warning_1_scouts", "trigger": {"on": "day_start"},
   "conditions": [{"fact": "day", "op": ">=", "value": 12},
                  {"fact": "quest_stage", "args": {"quest": "raid_warning"}, "op": "==", "value": ""}],
   "repeat": "once",
   "effects": [{"command": "story_message", "payload": {"text": "story.raid_warning.scouts", "severity": "warning"}},
               {"command": "set_quest_stage", "payload": {"quest": "raid_warning", "stage": "warned"}}]},

  {"id": "raid_warning_2_arrive", "trigger": {"on": "day_start"},
   "conditions": [{"fact": "quest_stage", "args": {"quest": "raid_warning"}, "op": "==", "value": "warned"},
                  {"fact": "days_in_stage", "args": {"quest": "raid_warning"}, "op": ">=", "value": 2}],
   "repeat": "once",
   "effects": [{"command": "spawn_incident", "payload": {"id": "raider_incursion"}},
               {"command": "story_message", "payload": {"text": "story.raid_warning.arrived", "severity": "danger"}},
               {"command": "set_quest_stage", "payload": {"quest": "raid_warning", "stage": "incoming"}}]},

  {"id": "raid_warning_3_repelled", "trigger": {"on": "day_start"},
   "conditions": [{"fact": "quest_stage", "args": {"quest": "raid_warning"}, "op": "==", "value": "incoming"},
                  {"fact": "days_in_stage", "args": {"quest": "raid_warning"}, "op": ">=", "value": 1},
                  {"fact": "actor_count", "args": {"faction": "raiders"}, "op": "==", "value": 0}],
   "repeat": "once",
   "effects": [{"command": "set_quest_stage", "payload": {"quest": "raid_warning", "stage": "repelled"}},
               {"command": "story_message", "payload": {"text": "story.raid_warning.repelled", "severity": "info"}}]}
]
```

`raider_incursion` becomes `"draw": "story"`, so the warning is never skipped by a daily-draw
raid. If incidents are disabled for the world, step 2's `spawn_incident` preview is rejected
(`invalid_target`, "Incidents are disabled"), the rule emits `story_rule_skipped` and stays
pending; the quest does not lie about raiders that never came. The "none are left" check
polls on `day_start` because the core has no death event yet; an `actor_died` event (F8)
would let step 3 react the same tick.

### C. The first-winter quest

A visible quest: prepare, live through the winter, and record whether the colony was ready.

```json
{"id": "first_winter", "title": "story.first_winter.title", "visible": true,
 "stages": [{"id": "prepare"}, {"id": "winter"}, {"id": "survived", "terminal": true},
            {"id": "lost", "terminal": true}]}
```

```json
[
  {"id": "first_winter_1_announce", "trigger": {"on": "day_start"},
   "conditions": [{"fact": "days_until_window", "args": {"window": "winter"}, "op": "<=", "value": 10},
                  {"fact": "days_until_window", "args": {"window": "winter"}, "op": ">=", "value": 0},
                  {"fact": "quest_stage", "args": {"quest": "first_winter"}, "op": "==", "value": ""}],
   "repeat": "once",
   "effects": [{"command": "set_quest_stage", "payload": {"quest": "first_winter", "stage": "prepare"}},
               {"command": "story_message", "payload": {"text": "story.first_winter.prepare", "severity": "info", "food": 30}}]},

  {"id": "first_winter_2_ready", "trigger": {"on": "day_start"},
   "conditions": [{"fact": "quest_stage", "args": {"quest": "first_winter"}, "op": "==", "value": "prepare"},
                  {"fact": "window_open", "args": {"window": "winter"}, "op": "==", "value": 1},
                  {"fact": "food_count", "op": ">=", "value": 30}],
   "repeat": "once",
   "effects": [{"command": "set_story_flag", "payload": {"flag": "first_winter_ready", "value": 1}},
               {"command": "set_quest_stage", "payload": {"quest": "first_winter", "stage": "winter"}},
               {"command": "story_message", "payload": {"text": "story.first_winter.ready", "severity": "info"}}]},

  {"id": "first_winter_3_short", "trigger": {"on": "day_start"},
   "conditions": [{"fact": "quest_stage", "args": {"quest": "first_winter"}, "op": "==", "value": "prepare"},
                  {"fact": "window_open", "args": {"window": "winter"}, "op": "==", "value": 1}],
   "repeat": "once",
   "effects": [{"command": "set_quest_stage", "payload": {"quest": "first_winter", "stage": "winter"}},
               {"command": "story_message", "payload": {"text": "story.first_winter.short", "severity": "warning"}}]},

  {"id": "first_winter_4_survived", "trigger": {"on": "day_start"},
   "conditions": [{"fact": "quest_stage", "args": {"quest": "first_winter"}, "op": "==", "value": "winter"},
                  {"fact": "window_open", "args": {"window": "winter"}, "op": "==", "value": 0},
                  {"fact": "colonist_count", "op": ">=", "value": 1}],
   "repeat": "once",
   "effects": [{"command": "set_quest_stage", "payload": {"quest": "first_winter", "stage": "survived"}},
               {"command": "story_message", "payload": {"text": "story.first_winter.survived", "severity": "info"}}]},

  {"id": "first_winter_5_lost", "trigger": {"on": "day_start"},
   "conditions": [{"fact": "quest_stage", "args": {"quest": "first_winter"}, "op": "==", "value": "winter"},
                  {"fact": "colonist_count", "op": "==", "value": 0}],
   "repeat": "once",
   "effects": [{"command": "set_quest_stage", "payload": {"quest": "first_winter", "stage": "lost"}},
               {"command": "end_scenario", "payload": {"outcome": "lost", "text": "story.first_winter.lost"}}]}
]
```

Steps 2 and 3 show the live-state rule: on the day winter opens, `_2_ready` (lower id) runs
first and, when food is enough, moves the quest to `winter`; `_3_short` then sees
`quest_stage != "prepare"` and does not fire. When food is short only `_3_short` fires. The
`first_winter_ready` flag is read by later content (a scenario score, a follow-up quest),
which also keeps the "flag read but never set" cross-check meaningful.

What it needs that does not exist yet: a `winter` calendar window. `calendar.json` has only
the `sow` window and `calendar.schema.json` requires every window to name a `labour`. The
code task either allows a window without `labour` (and without `boost`) or waits for the
owner's pending month/year calendar decision (`BACKLOG.md`, Parked). The rules above do not
change either way: they read `window_open`/`days_until_window` by window id.

## Alternatives considered

- **Story beats as code in `WorldState` or a new `story/*.gd` per beat.** What the audit found
  would happen by default. Rejected by ADR 011: every beat would grow the façade and none
  would be content a designer or a pack (A13) can add.
- **Effects as direct module calls** (the giver calls `IncidentScheduler.force_spawn()` or
  mutates flags itself). Smaller today, but it bypasses command validation, `preview()`, the
  event log and A11's replay. Commands give all four for free, and the cost (four small
  command types) is paid once.
- **A general expression language or embedded script** (`"day >= 12 and not flag('x')"`).
  More expressive, but it needs a parser, has unbounded cost per evaluation, and is hard to
  cross-check against the registry. A closed fact vocabulary with AND-only conditions covers
  the three examples; OR is two rules. Revisit only if real content needs it.
- **Polling every rule every tick.** Simplest evaluation, but it costs `rules × facts` every
  tick and fights the A0 budgets. Triggers keep the cost proportional to what happened.
- **Folding the incident daily draw into story rules now** (one rule per incident with
  `chance_percent`). It is the long-term shape, but it changes which incidents fire for every
  existing seed (a different RNG stream and order), which is a behaviour change on its own
  and breaks determinism tests. Deferred: `"draw": "story"` lets content opt out of the daily
  draw one row at a time, and a later task can retire the draw when no row uses it.
- **Applying effects immediately and letting their events trigger more rules in the same
  tick.** Gives same-tick chains, but makes loops possible inside one tick and makes order
  depend on effect side effects. One hop per tick is easy to reason about and still lets a
  chain run at simulation speed.
- **Persisting the event cursor and the event backlog** so `event` rules never miss a
  pre-save event. Would make events part of the save (A6 explicitly avoids that). Rejected;
  the limitation is documented and `day_start` + conditions covers the cases that matter.

## Consequences

- Story content is data: a new beat, quest or chain is rows in `story.json`/`quests.json`
  plus text keys, validated at load. A new fact or a new effect command is the only code
  change, each with a test.
- The layer is one more job giver: no colonist loop, no state machine outside the toil
  executor, no new extension *kind* beyond a content collection. It adds one phase to the
  tick pipeline and one module (`story/story_giver.gd`, expected well under the 800-line cap)
  plus one command-handler family.
- Every story-driven change is an ordinary command, so it is previewable, logged and
  replayable, and a rejected beat is visible (`story_rule_skipped`) instead of silently
  half-applied.
- The save grows one key with a migration; the hash covers it.
- Known limits, accepted: no player choices yet (a later `story_choice` command answering a
  `story_prompt` event fits the same model); no OR/NOT beyond `!=` and two rules; `event`
  rules can miss events emitted between the last tick and a save; one chain hop per tick.

### Code tasks this ADR creates

To be added to `docs/orca/BACKLOG.md` once the owner signs this ADR off. All wait for R12
(the tick pipeline and command router they plug into), as the audit's A12–A17 note says.

1. **S1: story content kinds.** `quests.json`, `story.json`, their schemas, registration in
   `ContentRegistry.COLLECTION_KINDS`, the cross-checks of section 2, and the optional
   `"draw"` field on incidents (`incidents.schema.json`, `IncidentScheduler._run_daily_draw()`
   skipping `"story"` rows). Tests: `test_content_registry.gd`, `test_incidents.gd`.
2. **S2: story commands.** `set_story_flag`, `set_quest_stage`, `story_message`,
   `end_scenario`: `CommandChecks` functions, an R10 handler family, the events they emit,
   rejection reasons in `commands/README.md`. Tests through `apply()`/`preview()`.
3. **S3: `StoryGiver` and its tick phase.** Trigger collection, id-ordered evaluation, facts,
   bindings, preview-then-apply, the per-tick budget, the salted RNG, the `story` phase in
   `TickPipeline`. Tests through real ticks: each worked example as a headless scenario, a
   same-seed `state_hash()` determinism check, the budget carry-over, a skipped rule.
4. **S4: story persistence.** `story` save key, module encode/decode/validate, schema bump,
   migration, fixture, `state_hash()` coverage, `save-system.md`. Test: save → load →
   identical hash mid-quest.
5. **S5: incident arrival event.** `incident_actor_arrived` from
   `IncidentScheduler.on_job_finished()` for lingering actors (needed by example A); ADR 034
   amendment.
6. **S6: story presentation.** Story messages in the alert list and a read-only quest list,
   through `TextTable` keys (A15). Viewer test.
7. **Content tasks** (after S1–S5): the three worked examples as real content, the `winter`
   calendar window (blocked on the owner's calendar decision) and A16's scenarios naming
   which story rules they enable.

## Acceptance criteria

- [ ] The owner signs off this ADR (status → accepted).
- [x] The affected canonical document is updated: `docs/architecture/extension-points.md`
      gains a "Story rule" entry pointing here.
- [x] Contracts, examples and tests: N/A for this design-only change; the code tasks above
      own them.
- [x] Save/migration impact is described (section 5) and assigned to S4.
- [x] The source-of-truth index still points to the authoritative location (`docs/decisions/`
      is indexed as a whole; no new canonical document).
