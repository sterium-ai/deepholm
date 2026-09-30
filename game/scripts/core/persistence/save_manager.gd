class_name SaveManager
extends RefCounted

## Slot policy on top of SaveIO's validate-before-replace writer/reader.
## One save directory (default "user://saves", injectable for tests)
## holds exactly four files:
##   - "manual.json"      -- the single manual save slot. Only save_manual()
##                            ever writes it; save_autosave() never touches it.
##   - "autosave-1.json"
##   - "autosave-2.json"  -- three rotating autosave slots.
##   - "autosave-3.json"
##
## Rotation order: each save_autosave() call writes to whichever of the three
## autosave files currently holds the oldest recorded (epoch, tick) pair (an
## empty or unreadable slot counts as oldest and is always picked first), so
## the newest write always replaces the oldest survivor -- never a fixed
## round-robin index. With four consecutive calls at the same epoch the 1st
## save is evicted by the 4th, leaving the 2nd/3rd/4th on disk. Recency is
## read from each slot's own recorded "epoch"/"tick" (state_codec.gd /
## game-state.schema.json), not file mtime or an in-memory counter, so
## rotation and load_best() both behave the same whether or not the process
## restarted between calls.
##
## "epoch" is a caller-supplied game-session marker, not a WorldState field: every save_manual()/save_autosave() call defaults to
## epoch 0 (an ordinary continuing game), but boot.gd's New Game control
## mints a strictly higher epoch (see next_epoch()/highest_known_epoch()
## below) for the fresh game it starts, so ordering below always compares
## (epoch, tick) lexicographically -- a higher epoch outranks any tick from a
## lower one. Raw tick alone is not a valid cross-game recency signal: an old
## game's autosave at tick 1000 must never outrank a brand-new game's manual
## save at tick 10 just because 1000 > 10. Within a
## single epoch, tick ordering behaves exactly as it always has.
##
## last-known-good pointer: get_last_known_good() reports the slot/file/tick
## of the most recent candidate this manager has itself seen validate --
## either by writing it (SaveIO.write_atomic() already validates and reads
## the candidate back before replacing the target) or by load_best()
## successfully reading it. The pointer only ever advances to a strictly
## newer validated tick; it never regresses and never reflects a candidate
## that failed validation.
##
## load_best() pools all four slots, orders the ones that exist newest-first
## by recorded tick, and tries SaveIO.read() on each in that order until one
## validates. Every candidate rejected along the way is reported, in trial
## order, with its file name and SaveIO's typed failure code/message; slots
## never reached because an earlier candidate already succeeded are not
## reported. No migration logic lives here: SaveIO.read() already delegates
## to save_migrations.gd for an older schema version.

const SaveIOType = preload("res://scripts/core/persistence/save_io.gd")
const StateCodecType = preload("res://scripts/core/persistence/state_codec.gd")

const DEFAULT_SAVE_DIR := "user://saves"
const MANUAL_FILE := "manual.json"
const AUTOSAVE_FILES := ["autosave-1.json", "autosave-2.json", "autosave-3.json"]
const MANUAL_SLOT := "manual"

var _save_dir: String
var _last_known_good = null

func _init(save_dir: String = DEFAULT_SAVE_DIR) -> void:
	_save_dir = save_dir
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(_save_dir))

func save_manual(world: WorldState, epoch: int = 0) -> Dictionary:
	var state: Dictionary = StateCodecType.encode(world)
	state["epoch"] = epoch
	var result: Dictionary = SaveIOType.write_atomic(_manual_path(), state)
	if result.get("ok", false):
		_advance_last_known_good(MANUAL_SLOT, _manual_path(), epoch, int(state["tick"]))
	return result

## Never writes or evicts the manual slot; only rotates among the three
## autosave files (see header comment for the eviction rule).
func save_autosave(world: WorldState, epoch: int = 0) -> Dictionary:
	var state: Dictionary = StateCodecType.encode(world)
	state["epoch"] = epoch
	var index := _pick_autosave_slot()
	var path := _autosave_path(index)
	var result: Dictionary = SaveIOType.write_atomic(path, state)
	if result.get("ok", false):
		_advance_last_known_good(_autosave_slot_name(index), path, epoch, int(state["tick"]))
	return result

## Returns {"ok": true, "slot", "file", "tick", "epoch", "state", "skipped"}
## for the newest slot that validates, or {"ok": false, "skipped"} if none
## do. "skipped" is an ordered Array of {"slot", "file", "code", "message"}
## for every rejected candidate tried before the result above.
func load_best() -> Dictionary:
	var ordered := _order_candidates_newest_first()
	var skipped: Array[Dictionary] = []
	for candidate in ordered:
		var result: Dictionary = SaveIOType.read(candidate["file"])
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

## Null until a candidate has actually validated (by write or by
## load_best()); afterward {"slot", "file", "epoch", "tick"} of the newest
## (epoch, tick) pair seen.
func get_last_known_good():
	return _last_known_good

## The highest "epoch" recorded across all four slots on disk (readable or
## not, matching _peek_epoch_tick()'s own tolerance), or -1 when none exist
## or none carry one. boot.gd's New Game control uses this (see next_epoch()
## below) to mint a session marker strictly newer than anything already
## saved, so a fresh game's own saves always outrank whatever came before
## regardless of tick.
func highest_known_epoch() -> int:
	var highest := -1
	for path in _all_slot_paths():
		var peeked = _peek_epoch_tick(path)
		if peeked != null and int(peeked["epoch"]) > highest:
			highest = int(peeked["epoch"])
	return highest

## A new epoch strictly greater than every epoch already recorded on disk.
## Callers that also track an epoch already active in memory (boot.gd) must
## still max() this against that in-memory value themselves -- this manager
## only knows what has actually been written.
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

## (epoch, tick) lexicographic ordering shared by every comparison in this
## file: a higher epoch always outranks a lower one regardless of tick;
## within the same epoch, the higher tick wins (see header comment).
static func _epoch_tick_before(epoch_a: int, tick_a: int, epoch_b: int, tick_b: int) -> bool:
	if epoch_a != epoch_b:
		return epoch_a < epoch_b
	return tick_a < tick_b

## Slot whose recorded (epoch, tick) is lowest; a missing or unreadable slot
## is treated as older than any recorded pair and is picked immediately.
func _pick_autosave_slot() -> int:
	var oldest_index := 0
	var oldest = null
	for i in AUTOSAVE_FILES.size():
		var path := _autosave_path(i)
		var peeked = _peek_epoch_tick(path)
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
		var peeked = _peek_epoch_tick(candidate["file"])
		present.append({
			"slot": candidate["slot"], "file": candidate["file"],
			"sort_epoch": int(peeked["epoch"]) if peeked != null else -1,
			"sort_tick": int(peeked["tick"]) if peeked != null else -1,
		})
	present.sort_custom(func(a, b): return _epoch_tick_before(int(b["sort_epoch"]), int(b["sort_tick"]), int(a["sort_epoch"]), int(a["sort_tick"])))
	return present

## Reads the "epoch"/"tick" recorded inside a candidate's own envelope
## without requiring it to pass integrity/schema validation, so a candidate
## that SaveIO.read() will later reject for a body reason (integrity
## mismatch, schema error) can still be ordered by its recorded position.
## Returns null when the file cannot even be parsed enough to find one (for
## example a truncated write), in which case callers fall back to treating
## it as oldest. "epoch" defaults to 0 for a pre-epoch-field body (matching
## SaveMigrations' own v19->v20 backfill) so an old save on disk from before
## epochs existed still orders sanely against a genuinely epoch-tagged one.
static func _peek_epoch_tick(path: String):
	if not FileAccess.file_exists(path):
		return null
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return null
	var text := file.get_as_text()
	file.close()
	var parsed = JSON.parse_string(text)
	if not (parsed is Dictionary):
		return null
	var state = parsed.get("state")
	if not (state is Dictionary):
		return null
	var tick = state.get("tick")
	if typeof(tick) != TYPE_INT and typeof(tick) != TYPE_FLOAT:
		return null
	var epoch = state.get("epoch", 0)
	if typeof(epoch) != TYPE_INT and typeof(epoch) != TYPE_FLOAT:
		epoch = 0
	return {"epoch": int(epoch), "tick": int(tick)}

func _manual_path() -> String:
	return _save_dir.path_join(MANUAL_FILE)

func _autosave_path(index: int) -> String:
	return _save_dir.path_join(AUTOSAVE_FILES[index])

func _autosave_slot_name(index: int) -> String:
	return "autosave-%d" % (index + 1)
