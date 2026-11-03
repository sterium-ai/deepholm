extends SceneTree

## A15 pseudo-locale test (ADR 052). Builds a pseudo-locale "qps" from
## data/text/en.json (every letter accented and the text bracketed, format
## specifiers and {names} kept), loads it through TextTable and proves:
## 1) every key resolves to its pseudo text, with the same placeholders as
##    English, and a key the locale lacks falls back to English, as does a
##    locale with no file at all;
## 2) every key the game can ask for resolves: key literals in the viewer,
##    content labels (tiles.json display.label, calendar.json window labels,
##    scenarios.json labels (A16),
##    read through the session ContentRegistry), the per-kind families the
##    viewer builds ("status.job.<kind>", "status.need.<kind>", ...), and every
##    command rejection reason, detail and remedy the core can return, read
##    from the core sources;
## 3) real rejected commands, sent through WorldState.apply(), render to text
##    with every {placeholder} filled.

const BootType = preload("res://scripts/boot.gd")
const TextTableType = preload("res://scripts/viewer/text_table.gd")
const StatusTextType = preload("res://scripts/viewer/status_text.gd")
const ColonistPanelType = preload("res://scripts/viewer/colonist_panel.gd")
const ControlBarType = preload("res://scripts/viewer/control_bar.gd")
const WorldStateType = preload("res://scripts/core/world_state.gd")
const ToilExecutorType = preload("res://scripts/core/jobs/toil_executor.gd")

const PSEUDO_LOCALE := "qps"
const PSEUDO_DIR := "user://test-text-pseudo-locale"
const EN_PATH := "res://data/text/en.json"
const VIEWER_DIR := "res://scripts/viewer"
const BOOT_PATH := "res://scripts/boot.gd"
const CORE_DIR := "res://scripts/core"
const SAVE_SOURCES := ["res://scripts/core/persistence/save_io.gd", "res://scripts/core/persistence/save_migrations.gd"]
## The key the pseudo locale deliberately omits, to prove the English fallback.
const DROPPED_KEY := "controls.pause"
## The first segment of every data/text key; a viewer literal of the form
## "<prefix>.<rest>" is a text key and must resolve.
const KEY_PREFIXES := ["controls", "incident", "work_table", "status", "save", "new_game", "colonists",
	"rejection", "recording", "tile", "calendar", "workbench"]
## Bookkeeping toils that are never a colonist's current toil (colonist_panel.gd).
const UNSHOWN_TOILS := ["reserve", "release_all"]
## save_wiring.gd's write-failure codes (SaveManager/SaveIO write path).
const SAVE_WRITE_CODES := ["write_failed", "write_interrupted", "rename_failed", "schema_error", "no_migration_available", "unknown"]
const ACCENTS := {"a": "à", "e": "é", "i": "î", "o": "ö", "u": "ü", "A": "À", "E": "É", "I": "Î", "O": "Ö", "U": "Ü",
	"c": "ç", "n": "ñ", "y": "ý"}

var _failed := false
var _placeholder := RegEx.create_from_string("%[-+0-9.]*[sdifxXcv%]|\\{[a-z_]+\\}")
var _key_literal := RegEx.create_from_string("\"([a-z_]+(?:\\.[a-z0-9_]+)+)\"")

func _init() -> void:
	var english := TextTableType.new()
	var pseudo_strings := _write_pseudo_locale(english)
	var pseudo := TextTableType.new(PSEUDO_LOCALE, PSEUDO_DIR)
	_check_pseudo_locale_loads(english, pseudo, pseudo_strings)
	var keys := _keys_the_game_asks_for()
	_expect(keys.size() > 150, "the key census must cover the game's text, got %d keys" % keys.size())
	print("test_text_pseudo_locale: %d keys the game asks for, %d in en.json" % [keys.size(), english.keys().size()])
	for key in keys:
		_expect(english.has_string(key), "key '%s' (%s) has no data/text/en.json entry" % [key, keys[key]])
		_expect(pseudo.get_string(key) == pseudo_strings.get(key, english.get_string(key)),
			"key '%s' must resolve through the pseudo locale" % key)
	_check_real_rejections_render(english)
	DirAccess.remove_absolute(PSEUDO_DIR.path_join(PSEUDO_LOCALE + ".json"))
	DirAccess.remove_absolute(PSEUDO_DIR.path_join("en.json"))
	DirAccess.remove_absolute(PSEUDO_DIR)
	if _failed:
		quit(1)
		return
	print("test_text_pseudo_locale: PASS")
	quit(0)

func _fail(message: String) -> void:
	push_error(message)
	_failed = true

func _expect(condition: bool, message: String) -> void:
	if not condition:
		_fail(message)

## Writes en.json and the pseudo locale (minus DROPPED_KEY) into PSEUDO_DIR;
## returns the pseudo strings.
func _write_pseudo_locale(english: TextTableType) -> Dictionary:
	DirAccess.make_dir_recursive_absolute(PSEUDO_DIR)
	var pseudo_strings := {}
	for key in english.keys():
		if key != DROPPED_KEY:
			pseudo_strings[key] = _pseudo(english.get_string(key))
	var en_file := FileAccess.open(PSEUDO_DIR.path_join("en.json"), FileAccess.WRITE)
	en_file.store_string(FileAccess.get_file_as_string(EN_PATH))
	en_file.close()
	var pseudo_file := FileAccess.open(PSEUDO_DIR.path_join(PSEUDO_LOCALE + ".json"), FileAccess.WRITE)
	pseudo_file.store_string(JSON.stringify(pseudo_strings, "  "))
	pseudo_file.close()
	return pseudo_strings

## "[!! ... !!]" around the text with letters accented, placeholders untouched.
func _pseudo(text: String) -> String:
	var out := ""
	var cursor := 0
	for found in _placeholder.search_all(text):
		out += _accent(text.substr(cursor, found.get_start() - cursor)) + found.get_string()
		cursor = found.get_end()
	return "[!! " + out + _accent(text.substr(cursor)) + " !!]"

func _accent(text: String) -> String:
	var out := ""
	for ch in text:
		out += String(ACCENTS.get(ch, ch))
	return out

func _placeholders(text: String) -> Array[String]:
	var found: Array[String] = []
	for item in _placeholder.search_all(text):
		found.append(item.get_string())
	return found

func _check_pseudo_locale_loads(english: TextTableType, pseudo: TextTableType, pseudo_strings: Dictionary) -> void:
	_expect(english.locale == "en" and english.keys().size() > 200, "en.json must load as the full key set")
	_expect(pseudo.locale == PSEUDO_LOCALE, "the pseudo locale's file must load, got locale '%s'" % pseudo.locale)
	for key in english.keys():
		if key == DROPPED_KEY:
			continue
		var text := pseudo.get_string(key)
		_expect(text == pseudo_strings[key] and text != english.get_string(key),
			"pseudo key '%s' must resolve to its pseudo text, got '%s'" % [key, text])
		_expect(_placeholders(text) == _placeholders(english.get_string(key)),
			"pseudo key '%s' must keep English's placeholders" % key)
	_expect(pseudo.get_string(DROPPED_KEY) == english.get_string(DROPPED_KEY),
		"a key the locale lacks must fall back to English")
	var pseudo_format := pseudo.format("controls.active_seed_label", [42])
	_expect(pseudo_format.begins_with("[!! ") and "42" in pseudo_format, "positional format must fill the pseudo text, got '%s'" % pseudo_format)
	var missing := TextTableType.new("zz", PSEUDO_DIR)
	_expect(missing.locale == "en" and missing.get_string("status.idle") == english.get_string("status.idle"),
		"a locale with no file must fall back to English")

## key -> where it comes from, for every key the game can ask the table for.
func _keys_the_game_asks_for() -> Dictionary:
	var keys := {}
	_add_viewer_key_literals(keys)
	_add_content_labels(keys)
	_add_viewer_families(keys)
	_add_rejection_codes(keys)
	return keys

func _add_viewer_key_literals(keys: Dictionary) -> void:
	var paths: Array[String] = [BOOT_PATH]
	for file_name in DirAccess.get_files_at(VIEWER_DIR):
		if file_name.ends_with(".gd"):
			paths.append(VIEWER_DIR.path_join(file_name))
	for path in paths:
		for found in _key_literal.search_all(FileAccess.get_file_as_string(path)):
			var key := found.get_string(1)
			# "controls.tool_" + id is a family prefix, enumerated in _add_viewer_families().
			if key.get_slice(".", 0) in KEY_PREFIXES and not key.ends_with("_"):
				keys[key] = path

## Content labels are keys (ADR 052), read through the session registry (A13).
func _add_content_labels(keys: Dictionary) -> void:
	var content := BootType.session_content()
	var tiles := content.list("tiles")
	_expect(not tiles.is_empty(), "the session registry must list tiles")
	for tile in tiles:
		keys[String(tile["display"]["label"])] = "tiles.json %s" % tile["id"]
	var windows: Array = content.document("calendar").get("windows", [])
	_expect(not windows.is_empty(), "the session registry must hold calendar windows")
	for window in windows:
		keys[String(window["label"])] = "calendar.json %s" % window["id"]
	var scenarios := content.list("scenarios")
	_expect(not scenarios.is_empty(), "the session registry must list scenarios")
	for scenario in scenarios:
		keys[String(scenario["label"])] = "scenarios.json %s" % scenario["id"]

func _add_viewer_families(keys: Dictionary) -> void:
	var content := BootType.session_content()
	for job in content.list("jobs"):
		keys["status.job.%s" % job["kind"]] = "jobs.json"
	for need in content.list("needs"):
		keys["status.need.%s" % need["kind"]] = "needs.json"
	for incident in content.list("incidents"):
		keys["incident.%s" % incident["id"]] = "incidents.json"
	for tool_key in ControlBarType.TOOL_KEYS:
		keys["controls.tool_%s" % tool_key] = "ControlBar.TOOL_KEYS"
	for kind in WorldStateType.LABOUR_KINDS:
		keys["work_table.labour.%s" % kind] = "WorldState.LABOUR_KINDS"
	for toil in ToilExecutorType.VOCABULARY:
		if toil not in UNSHOWN_TOILS:
			keys["status.toil.%s" % toil] = "ToilExecutor.VOCABULARY"
	for table in [ColonistPanelType.NEED_REASON_REMEDY, ColonistPanelType.TOOL_REASON_REMEDY, ColonistPanelType.TRAPPED_REASON_REMEDY]:
		for reason in table:
			keys["status.reason.%s" % reason] = "colonist_panel.gd"
			keys["status.remedy.%s" % table[reason]] = "colonist_panel.gd"
	var save_source := ""
	for path in SAVE_SOURCES:
		save_source += FileAccess.get_file_as_string(path)
	for found in RegEx.create_from_string("\"code\": \"([a-z_]+)\"").search_all(save_source):
		if found.get_string(1) != "ok":
			keys["save.reason.%s" % found.get_string(1)] = "save_io.gd"
	for code in SAVE_WRITE_CODES:
		keys["save.write_reason.%s" % code] = "save_wiring.gd"

## Every rejection reason, detail and remedy written in the core, plus the
## job-blocking reasons and remedies a colonist line shows.
func _add_rejection_codes(keys: Dictionary) -> void:
	var source := ""
	for path in _core_sources(CORE_DIR):
		source += FileAccess.get_file_as_string(path) + "\n"
	var patterns := {
		"\"detail\": \"([a-z_]+)\"": "rejection.%s",
		"\"reason\": \"([a-z_]+)\"": "status.reason.%s",
		"\"remedy\": \"([a-z_]+)\"": "status.remedy.%s",
		"[Rr]ejection\\([^\\n]*?, \"([a-z_]+)\",": "status.reason.%s",
		"reject\\([^\\n]*?, \"([a-z_]+)\",": "status.reason.%s",
		"BLOCKED_[A-Z_]+ := \"([a-z_]+)\"": "status.reason.%s",
		"REASON_NOT_ORDERED_BY_PLAYER := \"([a-z_]+)\"": "status.reason.%s",
		"block\\(job, [A-Z_]+, \"([a-z_]+)\"": "status.remedy.%s",
		"_reject\\([^,]+, \"[a-z_]+\", \"([a-z_]+)\"\\)": "status.remedy.%s",
	}
	for pattern in patterns:
		var matches := RegEx.create_from_string(pattern).search_all(source)
		_expect(not matches.is_empty(), "the core census pattern %s must match something" % pattern)
		for found in matches:
			keys[String(patterns[pattern]) % found.get_string(1)] = "core: %s" % pattern

func _core_sources(dir_path: String) -> Array[String]:
	var paths: Array[String] = []
	for file_name in DirAccess.get_files_at(dir_path):
		if file_name.ends_with(".gd"):
			paths.append(dir_path.path_join(file_name))
	for sub in DirAccess.get_directories_at(dir_path):
		paths.append_array(_core_sources(dir_path.path_join(sub)))
	return paths

func _check_real_rejections_render(english: TextTableType) -> void:
	var world := WorldStateType.new(4242, 10, 16, 16)
	var commands := [
		{"type": "chop", "payload": {"x": 0, "y": 0, "z": 0, "priority": 1}},
		{"type": "dig", "payload": {"x": 99, "y": 0, "z": 0, "priority": 1}},
		{"type": "place_object", "payload": {"x": 1, "y": 1, "z": 0, "kind": "no_such_kind"}},
		{"type": "set_faction", "payload": {"target": "nobody", "faction_id": "no_such_faction"}},
		{"type": "set_labour", "payload": {"colonist": "c1", "kind": "juggle", "level": 9}},
		{"type": "spawn_incident", "payload": {"id": "no_such_incident"}},
		{"type": "zone_remove", "payload": {"id": "no_such_zone"}},
		{"type": "cancel_job", "payload": {"job_id": "no_such_job"}},
		{"type": "accept_trade", "payload": {"trader_id": "nobody"}},
		{"type": "area_order", "payload": {"order": "juggle", "x": 0, "y": 0, "z": 0, "width": 1, "height": 1}},
		{"type": "no_such_command", "payload": {}},
	]
	for i in commands.size():
		var command: Dictionary = commands[i]
		command.merge({"actor": "player", "command_id": "pseudo_%d" % i, "tick": world.get_tick()})
		var result := world.apply(command)
		_expect(not result["ok"], "setup: %s must be rejected" % command["type"])
		if result["ok"]:
			continue
		var rejection: Dictionary = result["rejection"]
		_expect(not rejection.has("message"), "a %s rejection must carry codes only, got %s" % [command["type"], rejection])
		var text := StatusTextType.rejection_text(english, rejection)
		_expect(not text.is_empty() and not ("{" in text or "}" in text) and not text.begins_with("rejection."),
			"a %s rejection must render to filled text, got '%s' from %s" % [command["type"], text, rejection])
	var stale := world.apply({"actor": "player", "command_id": "pseudo_tick", "tick": world.get_tick() + 5, "type": "noop", "payload": {}})
	_expect(StatusTextType.rejection_text(english, stale["rejection"])
		== "Command tick %d does not match current tick %d." % [world.get_tick() + 5, world.get_tick()],
		"a tick_mismatch rejection must render its own ticks, got %s" % [stale])
