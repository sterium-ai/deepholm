extends RefCounted

## Save/load wiring for the debug viewer: loads the best save into a ready
## WorldState, mints game-session epochs, and turns SaveManager results into
## status text. Holds no references of its own; boot.gd passes its current
## save_manager/autosave_trigger in on every call (tests swap them).

const WorldStateType = preload("res://scripts/core/world_state.gd")
const SaveManagerType = preload("res://scripts/core/persistence/save_manager.gd")
const StateCodecType = preload("res://scripts/core/persistence/state_codec.gd")
const AutosaveTriggerType = preload("res://scripts/viewer/autosave_trigger.gd")
const TextTableType = preload("res://scripts/viewer/text_table.gd")

## SaveManager.load_best()'s own result; when "ok", "world" also holds the
## decoded WorldState. decode() always builds with incidents disabled: the
## caller (boot.gd) re-enables them before using the world.
static func load_best(save_manager: SaveManagerType) -> Dictionary:
	var result: Dictionary = save_manager.load_best()
	if not result.get("ok", false):
		return result
	var new_world: WorldStateType = StateCodecType.decode(result["state"])
	result["world"] = new_world
	return result

static func save_manual(save_manager: SaveManagerType, autosave_trigger: AutosaveTriggerType, world: WorldStateType, epoch: int) -> Dictionary:
	var result: Dictionary = save_manager.save_manual(world, epoch)
	if result.get("ok", false):
		# The player has now explicitly committed this game to disk: autosave
		# may safely resume (or keep running) for it --
		# a no-op when it was already enabled.
		autosave_trigger.set_enabled(true)
	return result

## A strictly new epoch for a fresh, unsaved colony (New Game, Debug
## Scenario), so its saves always outrank an older game's regardless of raw
## tick.
static func next_epoch(current_epoch: int, save_manager: SaveManagerType) -> int:
	return maxi(current_epoch, save_manager.highest_known_epoch()) + 1

## Every save_manual()/save_autosave() result is inspected here -- ok or not
## -- so a typed write failure (write_failed, write_interrupted, ...) is
## always shown instead of silently dropped. The last-saved status line only
## advances on a successful save; a failed one leaves it (and the last
## known-good save on disk) exactly as it was.
static func save_result_text(text_table: TextTableType, save_manager: SaveManagerType, result: Dictionary) -> String:
	if result.get("ok", false):
		return last_saved_text(text_table, save_manager)
	var code := String(result.get("code", "unknown"))
	var reason := text_table.get_string("save.write_reason.%s" % code)
	return text_table.format("status.save_failed", [reason])

static func last_saved_text(text_table: TextTableType, save_manager: SaveManagerType) -> String:
	var good = save_manager.get_last_known_good()
	if good == null:
		return text_table.get_string("status.last_saved_none")
	return text_table.format("status.last_saved_label", [int(good["tick"])])

## Builds a "resumed from autosave 2 (tick N) because autosave 1 was
## unreadable" style message: names the slot actually used, and -- only when
## load_best() had to skip a newer candidate to get there -- the first
## skipped slot's own typed reason, read straight from SaveIO's failure
## code rather than re-derived here.
static func resume_message(text_table: TextTableType, result: Dictionary) -> String:
	var winning := _pretty_slot(text_table, String(result["slot"]))
	var tick := int(result["tick"])
	var skipped: Array = result.get("skipped", [])
	if skipped.is_empty():
		return text_table.format("status.resumed_clean", [winning, tick])
	var first_skip: Dictionary = skipped[0]
	var skipped_pretty := _pretty_slot(text_table, String(first_skip["slot"]))
	var reason := text_table.get_string("save.reason.%s" % String(first_skip.get("code", "unknown")))
	return text_table.format("status.resumed_with_skip", [winning, tick, skipped_pretty, reason])

static func _pretty_slot(text_table: TextTableType, slot: String) -> String:
	if slot == SaveManagerType.MANUAL_SLOT:
		return text_table.get_string("save.slot.manual")
	return slot.replace("-", " ")
