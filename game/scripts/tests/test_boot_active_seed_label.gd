extends SceneTree

## Round 5 review finding 2: boot.gd's editable seed field (_seed_input) is
## only ever written by _on_new_game_pressed() -- after restarting into a
## saved colony it stayed blank, and after creating seed 2 and then loading a
## saved seed 42 colony it kept showing "2". No other UI element displayed
## the actually-running world's seed, so the "visible seed" requirement did
## not survive Load. Proves boot.gd's separate _active_seed_label (distinct
## from the editable draft field) always names the LIVE world's real seed:
## right after startup build, immediately after New Game, unaffected by
## cancelling a regeneration, and correctly restored (not the last unsaved
## draft) after a Save/Load round trip.

const Boot = preload("res://scripts/boot.gd")
const SaveManagerType = preload("res://scripts/core/persistence/save_manager.gd")

const SAVE_DIR := "user://test-boot-active-seed-label-saves"
const SEED_A := 42
const SEED_B := 2

var failures: Array[String] = []
var boot: Node

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	_cleanup_save_dir()
	boot = Boot.new()
	root.add_child(boot)
	# boot.gd's own _ready() builds the control bar only off-headless (see its
	# own doc comment); force it here so this headless run still exercises
	# _active_seed_label exactly like the real (non-headless) viewer does,
	# mirroring test_map_experience_seed42_flow.gd's own pattern.
	await process_frame
	if boot._map_view == null:
		boot._build_ui()
	# Reassign only AFTER _ready() has already used the default manager to
	# restore any prior autosave (same ordering test_map_experience_seed42_flow.gd
	# uses): every save/load in this test must stay isolated from a real
	# playthrough's own "user://saves" slot.
	boot.save_manager = SaveManagerType.new(SAVE_DIR)

	var initial_seed: int = boot.world.get_seed()
	_expect_label(initial_seed, "the active-seed label must name the world's real seed right after the UI is built")

	# New Game must update the active-seed label to the newly created world's
	# seed, distinctly from the editable draft field.
	boot._seed_input.text = str(SEED_A)
	boot._on_new_game_pressed()
	boot._on_new_game_confirmed()
	boot._new_game_confirm.hide()
	_expect(boot.world.get_seed() == SEED_A, "New Game must actually apply the seed typed into the field")
	_expect_label(SEED_A, "the active-seed label must switch to the new game's own seed")

	# Cancelling a regeneration (typing a new seed, opening the confirmation,
	# but never confirming) must leave the running world -- and its label --
	# completely untouched, even though the draft field itself now shows the
	# not-yet-applied seed.
	boot._seed_input.text = str(SEED_B)
	boot._on_new_game_pressed()
	boot._new_game_confirm.hide()
	_expect(boot.world.get_seed() == SEED_A, "cancelling New Game's confirmation must never regenerate the live world")
	_expect_label(SEED_A, "the active-seed label must stay on the live world's seed while a regeneration is only pending confirmation")
	_expect(boot._seed_input.text == str(SEED_B), "the draft seed field may still show the not-yet-applied seed")

	# Save seed A, then move on to an unsaved seed B, then Load: this is the
	# exact round 5 review scenario ("after creating seed 2 and loading a
	# saved seed 42 colony it still displays 2") -- Load must restore both the
	# world AND the label to the SAVED seed, not leave either on the last
	# unsaved draft.
	boot._on_save_pressed()
	_expect(FileAccess.file_exists(SAVE_DIR.path_join("manual.json")), "saving seed %d's game must succeed" % SEED_A)
	boot._seed_input.text = str(SEED_B)
	boot._on_new_game_pressed()
	boot._on_new_game_confirmed()
	boot._new_game_confirm.hide()
	_expect(boot.world.get_seed() == SEED_B, "the second New Game must actually apply seed %d" % SEED_B)
	_expect_label(SEED_B, "the active-seed label must switch to the unsaved second game's seed")

	boot._on_load_pressed()
	_expect(boot.world.get_seed() == SEED_A, "Load must restore the saved seed %d world, not remain on the unsaved draft seed %d" % [SEED_A, SEED_B])
	_expect_label(SEED_A, "the active-seed label must reflect the loaded world's saved seed, not the last New Game draft")

	boot.queue_free()
	await process_frame
	_cleanup_save_dir()
	if failures.is_empty():
		print("test_boot_active_seed_label: PASS")
		quit()
	else:
		for failure in failures:
			push_error(failure)
		quit(1)

func _expect_label(seed_value: int, message: String) -> void:
	var expected := "Active seed: %d" % seed_value
	_expect(boot._active_seed_label != null and boot._active_seed_label.text == expected,
		"%s (expected '%s', got '%s')" % [message, expected, boot._active_seed_label.text if boot._active_seed_label != null else "<null>"])

func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)

func _cleanup_save_dir() -> void:
	var absolute := ProjectSettings.globalize_path(SAVE_DIR)
	var dir := DirAccess.open(absolute)
	if dir == null:
		return
	dir.list_dir_begin()
	var file_name := dir.get_next()
	while file_name != "":
		if not dir.current_is_dir():
			dir.remove(file_name)
		file_name = dir.get_next()
	dir.list_dir_end()
