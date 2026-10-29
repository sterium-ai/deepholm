class_name SaveManager
extends RefCounted

## Slot policy on top of SaveIO's validate-before-replace writer/reader. One directory
## (default "user://saves") holds "manual.json" (written only by save_manual()) and three
## rotating "autosave-N.json" slots.
## Recency is the (epoch, tick) recorded inside each slot, compared lexicographically, never
## file mtime: a higher epoch (a New Game, see next_epoch()) outranks any tick of a lower one.
## save_autosave() overwrites the oldest autosave slot (empty/unreadable counts as oldest).
## load_best() tries the slots newest-first until one validates and reports every rejected
## candidate in trial order. The last-known-good pointer only advances to a strictly newer
## validated save. Migrations live in SaveIO.read()/save_migrations.gd, not here.
## Reads are checked against the session ContentRegistry given at construction (A13b): a slot
## made on other content packs is skipped with content_packs_mismatch. A write is checked
## against the registry of the world it encodes.

const SaveIOType = preload("res://scripts/core/persistence/save_io.gd")
const StateCodecType = preload("res://scripts/core/persistence/state_codec.gd")
const ContentRegistryType = preload("res://scripts/core/content/content_registry.gd")

const DEFAULT_SAVE_DIR := "user://saves"
const MANUAL_FILE := "manual.json"
const AUTOSAVE_FILES := ["autosave-1.json", "autosave-2.json", "autosave-3.json"]
const MANUAL_SLOT := "manual"

var _save_dir: String
var _last_known_good: Variant = null
## The session registry; null until first needed when none was given (then the base bundle).
var _content: ContentRegistryType

func _init(save_dir: String = DEFAULT_SAVE_DIR, content: ContentRegistryType = null) -> void:
	_save_dir = save_dir
	_content = content
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(_save_dir))

func save_manual(world: WorldState, epoch: int = 0) -> Dictionary:
	var state: Dictionary = StateCodecType.encode(world)
	state["epoch"] = epoch
	var result: Dictionary = SaveIOType.write_atomic(_manual_path(), state, Callable(), Callable(), StateCodecType.content_of(world))
	if result.get("ok", false):
		_advance_last_known_good(MANUAL_SLOT, _manual_path(), epoch, int(state["tick"]))
	return result

## Never touches the manual slot; overwrites the oldest autosave.
func save_autosave(world: WorldState, epoch: int = 0) -> Dictionary:
	var state: Dictionary = StateCodecType.encode(world)
	state["epoch"] = epoch
	var index := _pick_autosave_slot()
	var path := _autosave_path(index)
	var result: Dictionary = SaveIOType.write_atomic(path, state, Callable(), Callable(), StateCodecType.content_of(world))
	if result.get("ok", false):
		_advance_last_known_good(_autosave_slot_name(index), path, epoch, int(state["tick"]))
	return result

## {"ok": true, "slot", "file", "tick", "epoch", "state", "skipped"} for the newest slot that
## validates, else {"ok": false, "skipped"}; "skipped" lists rejected candidates in order.
func load_best() -> Dictionary:
	var ordered := _order_candidates_newest_first()
	var skipped: Array[Dictionary] = []
	for candidate in ordered:
		var result: Dictionary = SaveIOType.read(candidate["file"], get_content())
		if result.get("ok", false):
			var state: Dictionary = result["state"]
			var epoch := int(state.get("epoch", 0))
			_advance_last_known_good(candidate["slot"], candidate["file"], epoch, int(state["tick"]))
			return {
				"ok": true, "slot": candidate["slot"], "file": candidate["file"],
				"tick": int(state["tick"]), "epoch": epoch, "state": state, "skipped": skipped,
			}
		skipped.append({
			"slot": candidate["slot"], "file": candidate["file"],
			"code": result.get("code", "unknown"), "message": result.get("message", ""),
		})
	return {"ok": false, "skipped": skipped}

## The session registry loads are checked against; a loaded state decodes on it.
func get_content() -> ContentRegistryType:
	if _content == null:
		_content = ContentRegistryType.new()
	return _content

## Null until something validated; then {"slot", "file", "epoch", "tick"} of the newest seen.
func get_last_known_good():
	return _last_known_good

## The highest "epoch" recorded in any slot on disk (readable or not), or -1.
func highest_known_epoch() -> int:
	var highest := -1
	for path in _all_slot_paths():
		var peeked: Variant = _peek_epoch_tick(path)
		if peeked != null and int(peeked["epoch"]) > highest:
			highest = int(peeked["epoch"])
	return highest

## A new epoch above every one on disk; boot.gd still max()es it with its in-memory epoch.
func next_epoch() -> int:
	return highest_known_epoch() + 1

func _all_slot_paths() -> Array[String]:
	var paths: Array[String] = [_manual_path()]
	for i in AUTOSAVE_FILES.size():
		paths.append(_autosave_path(i))
	return paths

func _advance_last_known_good(slot: String, file: String, epoch: int, tick: int) -> void:
	if _last_known_good != null and _epoch_tick_before(epoch, tick, int(_last_known_good["epoch"]), int(_last_known_good["tick"])):
		return
	_last_known_good = {"slot": slot, "file": file, "epoch": epoch, "tick": tick}

## (epoch, tick) lexicographic order: a higher epoch wins regardless of tick.
static func _epoch_tick_before(epoch_a: int, tick_a: int, epoch_b: int, tick_b: int) -> bool:
	if epoch_a != epoch_b:
		return epoch_a < epoch_b
	return tick_a < tick_b

## Slot whose recorded (epoch, tick) is lowest; a missing or unreadable slot
## is treated as older than any recorded pair and is picked immediately.
func _pick_autosave_slot() -> int:
	var oldest_index := 0
	var oldest: Variant = null
	for i in AUTOSAVE_FILES.size():
		var path := _autosave_path(i)
		var peeked: Variant = _peek_epoch_tick(path)
		if peeked == null:
			return i
		if oldest == null or _epoch_tick_before(int(peeked["epoch"]), int(peeked["tick"]), int(oldest["epoch"]), int(oldest["tick"])):
			oldest = peeked
			oldest_index = i
	return oldest_index

func _order_candidates_newest_first() -> Array[Dictionary]:
	var candidates: Array[Dictionary] = [{"slot": MANUAL_SLOT, "file": _manual_path()}]
	for i in AUTOSAVE_FILES.size():
		candidates.append({"slot": _autosave_slot_name(i), "file": _autosave_path(i)})

	var present: Array[Dictionary] = []
	for candidate in candidates:
		if not FileAccess.file_exists(candidate["file"]):
			continue
		var peeked: Variant = _peek_epoch_tick(candidate["file"])
		present.append({
			"slot": candidate["slot"], "file": candidate["file"],
			"sort_epoch": int(peeked["epoch"]) if peeked != null else -1,
			"sort_tick": int(peeked["tick"]) if peeked != null else -1,
		})
	present.sort_custom(func(a, b): return _epoch_tick_before(int(b["sort_epoch"]), int(b["sort_tick"]), int(a["sort_epoch"]), int(a["sort_tick"])))
	return present

## The recorded epoch/tick without full validation, so a body-invalid candidate can still be
## ordered; null when unparseable (treated as oldest). A missing epoch reads as 0.
static func _peek_epoch_tick(path: String):
	if not FileAccess.file_exists(path):
		return null
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return null
	var text := file.get_as_text()
	file.close()
	var parsed: Variant = JSON.parse_string(text)
	if not (parsed is Dictionary):
		return null
	var state: Variant = parsed.get("state")
	if not (state is Dictionary):
		return null
	var tick: Variant = state.get("tick")
	if typeof(tick) != TYPE_INT and typeof(tick) != TYPE_FLOAT:
		return null
	var epoch: Variant = state.get("epoch", 0)
	if typeof(epoch) != TYPE_INT and typeof(epoch) != TYPE_FLOAT:
		epoch = 0
	return {"epoch": int(epoch), "tick": int(tick)}

func _manual_path() -> String:
	return _save_dir.path_join(MANUAL_FILE)

func _autosave_path(index: int) -> String:
	return _save_dir.path_join(AUTOSAVE_FILES[index])

func _autosave_slot_name(index: int) -> String:
	return "autosave-%d" % (index + 1)
