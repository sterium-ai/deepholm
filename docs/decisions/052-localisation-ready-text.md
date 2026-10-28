# ADR 052: Codes in the core, words in `data/text/<locale>.json`

> **In short:** The simulation never returns English sentences any more. A rejected command
> carries its reason code plus a `params` dictionary of codes and values, and content labels
> are text keys. All player text lives in `data/text/en.json`; the viewer's `TextTable` loads
> `data/text/<locale>.json` on top of it, so a key a translation lacks still shows English.

- **Status:** accepted
- **Date:** 2026-10-28
- **Scope:** simulation (command rejection shape), content (`tiles.json`, `calendar.json`
  labels), presentation (`TextTable`, viewer text)
- **Depends on:** ADR 048 (composed core), ADR 050 (command observer; unaffected)
- **Implements:** BACKLOG A15; `docs/architecture/foundation-audit.md` section 3.7

## Context

The foundation audit (3.7) found three things standing between the game and a translation:

- the core returned an English `message` next to every stable rejection `reason` (68 literal
  sites across `command_checks.gd`, `area_orders.gd`, `construction_system.gd`,
  `command_router.gd`, `trade_system.gd` and the command handlers);
- viewer scripts still held English literals (`boot.gd`, `colonist_panel.gd`,
  `control_bar.gd`, `new_game_dialog.gd`, `status_text.gd`), and two status lines showed a raw
  reason code to the player;
- content embedded English labels (`tiles.json` `display.label`, `calendar.json` `label`).

`TextTable` already existed but read only `en.json`, with no locale and no fallback.

## Decision

1. **Rejection shape.** `{"ok": false, "rejection": {command_id, actor, reason, params, tick}}`
   replaces the `message` field with `params`, a Dictionary holding no player text:
   - `"detail"`: a snake_case code naming the rule that failed (`target_not_tree`,
     `unknown_object_kind`, `tick_mismatch`, ...). One code per distinct old message.
   - `"remedy"`: for a rejection `JobQueue` produced (or `accept_trade`'s missing item), the
     queue's remedy code, which used to be passed through as the "message".
   - any other key: a named value the text needs (`type`, `kind`, `trader_id`,
     `command_tick`, `current_tick`, ...).
   Reason codes are unchanged. The `command_rejected` event already carried only `reason`, so
   the event log, `state_hash()` and saves are unchanged.
2. **Text.** `rejection.<detail>` entries in `en.json` hold the old English sentences, with
   `{name}` placeholders for the values; `StatusText.rejection_text()` picks
   `rejection.<detail>`, else `status.remedy.<remedy>`, else `status.reason.<reason>`.
3. **Locale.** `TextTable.new(locale, text_dir)` loads `en.json` as the complete key set and
   `<locale>.json` over it; a missing key or a missing locale file falls back to English.
   `boot.gd` asks for a `--locale=<code>` user argument, else the OS language. Only `en.json`
   ships; translations are out of scope.
4. **Content labels are keys.** `tiles.json` `display.label` is `tile.<id>` and the calendar
   window label is `calendar.window.<id>`; their schemas say so. The calendar alert event
   carries the key and the work-table banner resolves it (a label that is not a key, as in
   test calendars, is shown as written).
5. **Enforcement.** `test_viewer_text_lint.gd` fails on a player-facing literal in
   `viewer/*.gd` or `boot.gd` (developer diagnostics are exempt: `print`/`push_*`/`assert`
   lines and lines marked `# dev-text`). `test_text_pseudo_locale.gd` builds a pseudo locale
   and proves every key the game can ask for resolves: viewer key literals, content labels
   (through the session `ContentRegistry`), the per-kind families the viewer builds, and every
   reason, detail and remedy code written in the core.

## Alternatives considered

- **Godot `TranslationServer` / `tr()` with `.po` or CSV.** It would tie the text format to
  Godot's importer and need generated `.translation` resources; a JSON table the existing
  `TextTable` already reads keeps the data hand-editable and testable headless. A later switch
  stays possible because every string already goes through one class.
- **Keep `message` next to `params`.** Cheaper, but the core would still own English, and a
  caller could keep showing it; the goal is that the core cannot.
- **Message keys instead of detail codes (`"message_key": "rejection.target_not_tree"`).**
  It puts a viewer concern (the key layout) into the core; a code is enough.

## Consequences

- A command that adds a rejection adds a `detail` code and its `en.json` line in the same
  change; the pseudo-locale test fails otherwise.
- `rejection.<detail>` English is the old message text, so behaviour visible today is the same,
  except that the build-rejected and incident-not-started status lines now show the sentence
  instead of the raw reason code. One sentence differs in case: `job_order_payload` used to
  capitalise the command type (`type.capitalize()`, "Dig requires ..."); it now shows the type
  id as given ("dig requires ..."), like the other messages that start with an identifier
  (`place_object requires ...`, `kind must be ...`). Capitalising is a language rule, so it
  belongs in a translation's own sentence, not in code for one key.
- Developer-facing diagnostics (save, content-registry and replay errors) keep their English
  `message` next to a `code`; the viewer already maps save codes to `save.reason.*` text.
- Item, object, faction and actor ids still appear raw inside some lines (held tool kind,
  hands, trade offers, incident faction). Display names for those kinds are content work for a
  later task.

## Acceptance criteria

- [x] `game/scripts/core/commands/README.md` and `docs/architecture/orders-and-movement.md`
  describe the new rejection shape.
- [x] Schemas (`tiles.schema.json`, `calendar.schema.json`) describe labels as keys; tests
  updated (`test_calendar.gd`, `test_work_table_panel.gd`, `test_world_state_determinism.gd`)
  and added (`test_viewer_text_lint.gd`, `test_text_pseudo_locale.gd`).
- [x] Save/migration impact: none (rejections and event data are not persisted).
- [x] The source-of-truth index is unchanged (`docs/decisions/` is already listed).
